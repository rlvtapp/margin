import SwiftUI
#if os(macOS)
import AppKit

/// Selecting text by dragging past the top or bottom of the reader scrolls it, so a selection
/// can run on beyond what's on screen. A mail's text is a web view (or a text) at its full
/// height inside the reader's scroll view, so nothing scrolls by itself while dragging: this
/// scrolls the reader and tells the view under the pointer the drag went on.
@MainActor
final class DragSelectScroll {
    static let shared = DragSelectScroll()
    private var monitor: Any?
    private var scrollViews = NSHashTable<NSScrollView>.weakObjects()
    private weak var active: NSScrollView?
    private var last: NSEvent?
    private var timer: Timer?

    /// How close to an edge the pointer starts scrolling, and the most scrolled per tick.
    nonisolated static let margin: CGFloat = 14
    nonisolated static let fastest: CGFloat = 44

    /// Points to scroll this tick: positive towards the end of the mail, negative towards its
    /// start, zero while the pointer is well inside. Faster the further past the edge.
    /// `top` and `bottom` are the visible stretch on screen, `pointer` between or beyond them,
    /// all measured downwards.
    nonisolated static func step(pointer: CGFloat, top: CGFloat, bottom: CGFloat) -> CGFloat {
        if pointer > bottom - margin { return min(fastest, 3 + (pointer - (bottom - margin)) * 0.3) }
        if pointer < top + margin { return -min(fastest, 3 + ((top + margin) - pointer) * 0.3) }
        return 0
    }

    func watch(_ scrollView: NSScrollView) {
        scrollViews.add(scrollView)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            stop()
            active = scrollViews.allObjects.first { view in
                view.window === event.window && view.window != nil
                    && view.convert(view.bounds, to: nil).contains(event.locationInWindow)
            }
        case .leftMouseDragged:
            guard active != nil else { return }
            last = event
            if timer == nil, speed() != 0 {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                    MainActor.assumeIsolated { DragSelectScroll.shared.tick() }
                }
                RunLoop.main.add(timer!, forMode: .eventTracking)
            }
        default:
            stop()
            active = nil
        }
    }

    private func speed() -> CGFloat {
        guard let view = active, let event = last else { return 0 }
        let frame = view.convert(view.bounds, to: nil)
        // Window coordinates run upwards; measure downwards from the frame's top.
        return Self.step(pointer: frame.maxY - event.locationInWindow.y, top: 0, bottom: frame.height)
    }

    private func tick() {
        guard let view = active, let event = last, let document = view.documentView,
              NSEvent.pressedMouseButtons & 1 == 1 else { stop(); return }
        let step = speed()
        guard step != 0 else { stop(); return }
        let clip = view.contentView
        let furthest = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        let before = origin.y
        origin.y = min(max(origin.y + (document.isFlipped ? step : -step), 0), furthest)
        guard origin.y != before else { return }
        clip.scroll(to: origin)
        view.reflectScrolledClipView(clip)
        // The pointer hasn't moved but the mail under it has: say the drag went on, so the
        // selection reaches the text that just came into view.
        if let again = NSEvent.mouseEvent(with: .leftMouseDragged, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: event.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            event.window?.sendEvent(again)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        last = nil
    }
}

/// Put inside a scroll view's content: finds that scroll view and has it scroll while a
/// selection is dragged past its edges.
struct ScrollsWhileSelecting: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                if let scrollView = self?.enclosingScrollView { DragSelectScroll.shared.watch(scrollView) }
            }
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}
#endif

extension View {
    /// On the Mac, the scroll view around this scrolls while text in it is being selected by
    /// dragging past its top or bottom. Touch screens scroll selections themselves.
    @ViewBuilder
    func scrollsWhileSelecting() -> some View {
        #if os(macOS)
        background(ScrollsWhileSelecting().allowsHitTesting(false))
        #else
        self
        #endif
    }
}
