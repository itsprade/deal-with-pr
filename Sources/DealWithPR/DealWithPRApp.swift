import SwiftUI
import AppKit

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
    }
}

/// Owns the store, starts polling at launch, and hides the Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PRStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
    }
}

/// The menu-bar label: an SF Symbol with the review count beside it when > 0.
private struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.pull")
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }
}
