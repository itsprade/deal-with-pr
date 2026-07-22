import SwiftUI
import AppKit
import UserNotifications
import Sparkle

@main
struct DealWithPRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: delegate.store)
        } label: {
            MenuBarLabel(count: delegate.store.reviewCount)
        }
        .menuBarExtraStyle(.window)

        Window("Deal with PR — Settings", id: "settings") {
            SettingsView(store: delegate.store, updater: delegate.updaterController.updater)
                .frame(width: 380)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Owns the store, starts polling at launch, hides the Dock icon, and opens the
/// relevant PR when a notification is clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = PRStore()
    // Sparkle auto-updater (checks the appcast, downloads, installs, relaunches).
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        store.start()
    }

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

/// The menu-bar label: the app logo with the review count beside it when > 0.
/// The logo is rendered to an NSImage because MenuBarExtra only reliably draws
/// Text/Image in the status bar (custom SwiftUI shapes get dropped).
private struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        let renderer = ImageRenderer(content: AppLogo(size: 16))
        renderer.scale = 2
        let logo = renderer.nsImage

        return HStack(spacing: 4) {
            if let logo {
                Image(nsImage: logo)
            } else {
                AppLogo(size: 16)
            }
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }
}
