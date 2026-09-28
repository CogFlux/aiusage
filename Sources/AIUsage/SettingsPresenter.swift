import AppKit
import SwiftUI

/// Owns the Settings window.
///
/// This used to be SwiftUI's `Settings` scene, which offers no handle on its window: from a
/// menu-bar app it opened behind whatever was in front, and nothing sent from outside reliably
/// raised it. Activation cannot be relied on either — since macOS 14 it is cooperative, and a
/// click in the menu-bar panel does not make this accessory app the active one, so `activate` is
/// a request the system declines. Ordering a window we own does not depend on being active.
@MainActor
enum SettingsPresenter {
    private static var window: NSWindow?
    private static var makeContent: (() -> AnyView)?
    private static var onOpen: (() -> Void)?

    /// Called once at launch with the view to host, environment objects already attached.
    /// `onOpen` runs on every open: the window is kept between opens, so `onAppear` fires only once.
    static func configure<Content: View>(onOpen: (() -> Void)? = nil, _ content: @escaping () -> Content) {
        self.onOpen = onOpen
        makeContent = { AnyView(content()) }
    }

    static func open() {
        guard let window = window ?? makeWindow() else { return }
        onOpen?()
        // The language can change while the window is closed; the view follows on its own.
        window.title = Strings.current.settings
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Unlike the call above, this does not wait for the app to be active.
        window.orderFrontRegardless()
        // The menu-bar panel is still dismissing and hands focus back to the app that had it,
        // which can put that app's windows back on top. Raise again once that has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard window.isVisible else { return }
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    private static func makeWindow() -> NSWindow? {
        guard let makeContent else { return nil }
        let hosting = NSHostingController(rootView: makeContent())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Kept after closing so reopening is instant and remembers the selected tab.
        window.isReleasedWhenClosed = false
        window.center()
        // Restores the last position when there is one.
        window.setFrameAutosaveName("AIUsageSettings")
        self.window = window
        return window
    }
}
