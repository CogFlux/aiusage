import AppKit
import SwiftUI

/// Keeps the menu bar panel hanging from the menu bar, exactly as tall as its content, when the
/// content changes height.
///
/// MenuBarExtra places the panel once, as it opens, and centres the content in the window. A later
/// change in the content's height (a refresh clearing an error line, a note appearing, a provider's
/// rows arriving) resizes the window around its bottom-left origin, so a panel that shrinks drops
/// away from the menu bar and one that grows rises into it. That resize can also stop short of the
/// content's height, and the leftover shows as blank bands above and below the content. Remember
/// the top edge the panel opened with and, while it is up, size the window to the content under it.
///
/// Used as the content's background, so this view's height is the content's height.
struct PanelTopPin: NSViewRepresentable {
    func makeNSView(context: Context) -> PinView { PinView() }
    func updateNSView(_ nsView: PinView, context: Context) {}

    final class PinView: NSView {
        /// The top edge as placed by MenuBarExtra; nil while the panel is not up.
        private var top: CGFloat?
        private var fitScheduled = false

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
            if window.isKeyWindow { opened() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleFit()
        }

        @objc private func opened(_ note: Notification? = nil) {
            top = window?.frame.maxY
            scheduleFit()
        }

        @objc private func closed(_ note: Notification) {
            top = nil
        }

        @objc private func resized(_ note: Notification) {
            scheduleFit()
        }

        /// Wait for the resize in progress to return before overriding it, and coalesce the
        /// several notifications one content change produces.
        private func scheduleFit() {
            guard top != nil, !fitScheduled else { return }
            fitScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.fitScheduled = false
                self?.fit()
            }
        }

        private func fit() {
            guard let window, window.isVisible, let top, bounds.height > 0 else { return }
            let frame = window.frame
            let height = bounds.height
            guard abs(frame.height - height) > 0.5 || frame.maxY != top else { return }
            window.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height),
                            display: true)
        }
    }
}
