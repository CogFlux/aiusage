import AppKit
import SwiftUI

/// Keeps the menu bar panel hanging from the menu bar when its content changes height.
///
/// MenuBarExtra places the panel once, as it opens. A later change in the content's height (a
/// refresh clearing an error line, a note appearing, a provider's rows arriving) resizes the
/// window around its bottom-left origin, so a panel that shrinks drops away from the menu bar and
/// one that grows rises into it. Remember the top edge the panel opened with and restore it after
/// every resize while it is up.
struct PanelTopPin: NSViewRepresentable {
    func makeNSView(context: Context) -> PinView { PinView() }
    func updateNSView(_ nsView: PinView, context: Context) {}

    final class PinView: NSView {
        /// The top edge as placed by MenuBarExtra; nil while the panel is not up.
        private var top: CGFloat?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self)
            top = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let center = NotificationCenter.default
            // The panel becomes key once it is placed and shown, and closes when it resigns key.
            // Resizes outside that span are MenuBarExtra placing it, which must not be undone.
            center.addObserver(self, selector: #selector(opened), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(closed), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: window)
            if window.isKeyWindow { top = window.frame.maxY }
        }

        @objc private func opened(_ note: Notification) {
            top = window?.frame.maxY
        }

        @objc private func closed(_ note: Notification) {
            top = nil
        }

        @objc private func resized(_ note: Notification) {
            guard let window, window.isVisible, let top, window.frame.maxY != top else { return }
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        }
    }
}
