#if os(macOS)
import AppKit
import SwiftUI

/// Puts the window's close, minimise and zoom buttons in the middle of Margin's top bar instead
/// of at the system's default height, with as much room to their left as above and below them.
/// AppKit lays the title bar out again on resizes, focus changes and full screen, so they're
/// placed again each time.
struct WindowButtonPlacement: NSViewRepresentable {
    let barHeight: CGFloat

    func makeNSView(context: Context) -> PlacementView { PlacementView(barHeight: barHeight) }

    func updateNSView(_ view: PlacementView, context: Context) {
        view.barHeight = barHeight
        view.place()
    }

    final class PlacementView: NSView {
        var barHeight: CGFloat
        private var observers: [NSObjectProtocol] = []

        init(barHeight: CGFloat) {
            self.barHeight = barHeight
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        /// Gives the title bar the top bar's height and centres the buttons in it.
        func place() {
            // In full screen the system shows the buttons in its own menu-bar strip.
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let height = barHeight
            let containerFrame = NSRect(x: container.frame.minX, y: window.frame.height - height,
                                        width: container.frame.width, height: height)
            if container.frame != containerFrame { container.frame = containerFrame }
            let titlebarFrame = NSRect(x: titlebar.frame.minX, y: 0, width: titlebar.frame.width, height: height)
            if titlebar.frame != titlebarFrame { titlebar.frame = titlebarFrame }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            let margin = ((height - close.frame.height) / 2).rounded()
            var x = margin
            for button in buttons {
                let origin = NSPoint(x: x, y: ((height - button.frame.height) / 2).rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
                x += button.frame.width + 6
            }
        }
    }
}
#endif
