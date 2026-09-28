import AppKit

/// Brings the Settings window to the front.
///
/// The app is an accessory (`LSUIElement`), which has two consequences: its windows open behind
/// whatever is in front, and since macOS 14 activation is cooperative — `activate` from a menu-bar
/// popover is a request the system may decline. Ordering the window forward directly interferes
/// with SwiftUI setting it up. What is left, and what reliably works, is to stop being an accessory
/// for as long as a real window is open: a regular app activates and its windows come forward
/// normally. The cost is that AIUsage appears in the Dock and owns the menu bar meanwhile, so the
/// policy goes back as soon as the last titled window closes.
@MainActor
enum SettingsPresenter {
    private static var observer: NSObjectProtocol?

    /// Call when the user asks for Settings, before or as the window is created.
    static func willOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            // The window is still listed during willClose; look again once it is gone.
            Task { @MainActor in restoreIfNothingLeftOpen() }
        }
    }

    /// The MenuBarExtra popover is a borderless panel, so "titled" picks out exactly the windows
    /// that need the app to be regular — Settings, and Sparkle's update dialogs.
    private static func restoreIfNothingLeftOpen() {
        let stillOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        if !stillOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
