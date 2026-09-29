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
    private static var makeContent: ((SettingsView.Tab) -> AnyView)?
    private static var onOpen: (() -> Void)?
    private static var tabs: NSTabViewController?

    /// Called once at launch with the page for each tab, environment objects already attached.
    /// `onOpen` runs on every open: the window is kept between opens, so `onAppear` fires only once.
    static func configure<Content: View>(onOpen: (() -> Void)? = nil,
                                         _ content: @escaping (SettingsView.Tab) -> Content) {
        self.onOpen = onOpen
        makeContent = { AnyView(content($0)) }
    }

    static func open() {
        guard let window = window ?? makeWindow() else { return }
        onOpen?()
        // The language can change while the window is closed; the pages follow on their own.
        relabel()
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
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsView.Tab.allCases {
            let page = NSHostingController(rootView: makeContent(tab))
            // The tab controller pins each page to its preferredContentSize, and a hosting
            // controller left to manage that keeps resetting it to the natural size — together
            // they hold the window at one size. So the natural size is only the starting point,
            // and a resize by the user becomes the page's size from then on.
            page.sizingOptions = [.minSize]
            page.preferredContentSize = page.view.fittingSize
            let item = NSTabViewItem(viewController: page)
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        // Opens at the page's natural size; once dragged, the window keeps the size it was given
        // across tabs, and a page that no longer fits scrolls.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: SettingsView.minWidth, height: 300)
        window.toolbarStyle = .preference
        // Kept after closing so reopening is instant and remembers the selected tab.
        window.isReleasedWhenClosed = false
        self.tabs = tabs
        self.window = window

        relabel()
        window.center()
        // Restores the last position when there is one.
        window.setFrameAutosaveName("AIUsageSettings")
        return window
    }

    /// Tab labels, and page titles, which the tab controller shows as the window title.
    private static func relabel() {
        guard let tabs else { return }
        for (item, tab) in zip(tabs.tabViewItems, SettingsView.Tab.allCases) {
            item.label = tab.title(Strings.current)
            item.viewController?.title = item.label
        }
        // The controller only passes a title up when the selection changes.
        let selected = tabs.selectedTabViewItemIndex
        if tabs.tabViewItems.indices.contains(selected) {
            window?.title = tabs.tabViewItems[selected].label
        }
    }
}
