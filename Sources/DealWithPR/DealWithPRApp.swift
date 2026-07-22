import SwiftUI
import AppKit
import Observation
import UserNotifications
import Sparkle

extension Notification.Name {
    /// Posted by the popover footer's gear button to open Settings.
    static let dwprOpenSettings = Notification.Name("dwpr.openSettings")
}

@main
struct DealWithPRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // The menu-bar icon, popover, and Settings window are all managed by
    // AppDelegate as real AppKit windows (so we own the glass). This placeholder
    // Settings scene just satisfies SwiftUI's "at least one scene" requirement;
    // it never appears for an accessory (menu-bar-only) app.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Borderless panel that can still become key (borderless windows can't by
/// default), so it dismisses itself when the user clicks away (resignKey).
final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the store, the menu-bar status item, the popover panel, and the Settings
/// window. Starts polling at launch, hides the Dock icon, and opens the relevant
/// PR when a notification is clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    let store = PRStore()
    // Sparkle auto-updater (checks the appcast, downloads, installs, relaunches).
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var statusItem: NSStatusItem!
    private var panel: PopoverPanel?
    private var hostingView: NSHostingView<ContentView>?
    private var settingsWindow: NSWindow?
    /// Debounces the status-button click that would otherwise re-open the panel
    /// immediately after resignKey has just closed it.
    private var lastClosed = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings), name: .dwprOpenSettings, object: nil
        )
        setupStatusItem()
        buildPanel()
        store.start()
    }

    // MARK: - Status item (menu-bar icon + badge)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = renderedLogo()
            button.image?.isTemplate = false
            button.imagePosition = .imageLeading
            button.action = #selector(togglePanel)
            button.target = self
        }
        updateBadge()
        observeBadge()
    }

    private func renderedLogo() -> NSImage? {
        let renderer = ImageRenderer(content: AppLogo(size: 18))
        renderer.scale = 2
        return renderer.nsImage
    }

    private func updateBadge() {
        let count = store.reviewCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
    }

    /// Re-render the badge whenever the review count changes (Observation).
    private func observeBadge() {
        withObservationTracking {
            _ = store.reviewCount
        } onChange: {
            Task { @MainActor in
                self.updateBadge()
                self.observeBadge()
            }
        }
    }

    // MARK: - Popover panel

    private func buildPanel() {
        let hosting = NSHostingView(rootView: ContentView(store: store))
        hosting.setFrameSize(hosting.fittingSize)
        self.hostingView = hosting

        let size = hosting.fittingSize
        let panel = PopoverPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        // A container clipped to the corner radius holds a full-bleed glass
        // backdrop with our content on top. Using the glass as a backdrop (not
        // wrapping our content in its `contentView`) avoids its inset margin,
        // which otherwise renders as a dark rim around the panel.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = popoverCornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.cornerRadius = 0   // the container does the clipping
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            backdrop = effect
        }
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)

        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container

        self.panel = panel
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            // Ignore the click that just dismissed it via resignKey.
            if Date().timeIntervalSince(lastClosed) < 0.2 { return }
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel, let hosting = hostingView,
              let button = statusItem.button, let buttonWindow = button.window else { return }

        store.refresh()   // refresh-on-open, like the old MenuBarExtra

        // Size to the current content, then anchor centered under the status item.
        let size = hosting.fittingSize
        panel.setContentSize(size)

        let buttonRect = button.convert(button.bounds, to: nil)
        let onScreen = buttonWindow.convertToScreen(buttonRect)
        var x = onScreen.midX - size.width / 2
        let y = onScreen.minY - size.height - 6

        if let screen = buttonWindow.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    // Dismiss the popover when the user clicks away (it resigns key). The
    // Settings window becoming key also dismisses it, which is fine.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        lastClosed = Date()
        panel?.orderOut(nil)
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if settingsWindow == nil {
            let root = SettingsView(store: store, updater: updaterController.updater)
                .frame(width: 380)
            let hosting = NSHostingView(rootView: AnyView(root))
            hosting.setFrameSize(hosting.fittingSize)

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Notifications

    // Show banners even while the app is active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    // Open the PR in the browser when a notification is clicked.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
