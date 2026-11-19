import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The arithmetic behind sliding and zooming the Day and Week grid, kept apart so it can be tested.
enum CalendarScroll {
    /// Letting go mid-slide: the days lock onto the nearer whole column. Returns the days to move
    /// and the slide left over (which then animates to zero).
    static func settle(slide: CGFloat, column: CGFloat) -> (days: Int, slide: CGFloat) {
        if slide < -column / 2 { return (1, slide + column) }
        if slide > column / 2 { return (-1, slide - column) }
        return (0, slide)
    }

    /// The hour height after a pinch, between the smallest that fills the view and 120.
    static func zoomed(_ height: Double, by magnification: CGFloat, smallest: Double) -> Double {
        min(max((height * Double(magnification)).rounded(), smallest), 120)
    }

    /// Where to scroll so the point `anchor` below the top of the view stays on the same time.
    static func anchoredScroll(scroll: CGFloat, anchor: CGFloat, ratio: Double) -> CGFloat {
        max((scroll + anchor) * CGFloat(ratio) - anchor, 0)
    }
}

#if os(macOS)
/// Two-finger sideways scrolling on Day and Week. Each swipe locks to one direction at its
/// start: sideways moves the days (and never the hours), up and down scrolls the hours (and
/// never sideways). Momentum carries on after the fingers lift; then `end` lets the days settle
/// on whole columns. A mouse wheel with Shift moves one day per notch.
struct DayScroller: NSViewRepresentable {
    let move: (CGFloat) -> Void
    let end: () -> Void
    let step: (Int) -> Void

    func makeNSView(context: Context) -> ScrollerView {
        let view = ScrollerView()
        update(view)
        return view
    }

    func updateNSView(_ view: ScrollerView, context: Context) { update(view) }

    private func update(_ view: ScrollerView) {
        view.move = move
        view.end = end
        view.step = step
    }

    final class ScrollerView: NSView {
        var move: (CGFloat) -> Void = { _ in }
        var end: () -> Void = {}
        var step: (Int) -> Void = { _ in }
        private var monitor: Any?
        private enum Lock { case sideways, upDown }
        private var lock: Lock?
        private var pending = CGSize.zero
        private var waitingForMomentum = false
        private var lastWheelStep = Date.distantPast

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Removed from its window (which happens before it goes away): stop watching.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        /// True when the event was used here (so the hours don't also scroll).
        private func handle(_ event: NSEvent) -> Bool {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            // Momentum of a sideways swipe: keep moving, then settle when it stops.
            if !event.momentumPhase.isEmpty {
                guard lock == .sideways else { return false }
                waitingForMomentum = false
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    lock = nil
                    end()
                } else {
                    move(dx)
                }
                return true
            }
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }

            if event.phase.isEmpty {
                // A mouse wheel: Shift makes it sideways, one day per notch.
                guard abs(dx) > abs(dy), dx != 0 else { return false }
                if Date().timeIntervalSince(lastWheelStep) > 0.06 {
                    lastWheelStep = Date()
                    step(dx < 0 ? 1 : -1)
                }
                return true
            }

            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                lock = nil
                pending = .zero
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                guard lock == .sideways else { lock = nil; return false }
                // Momentum may follow; if it doesn't, settle now.
                waitingForMomentum = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    guard let self, self.waitingForMomentum else { return }
                    self.waitingForMomentum = false
                    self.lock = nil
                    self.end()
                }
                return true
            }
            if lock == nil {
                pending.width += dx
                pending.height += dy
                guard abs(pending.width) + abs(pending.height) > 3 else { return true }
                lock = abs(pending.width) > abs(pending.height) ? .sideways : .upDown
                if lock == .sideways { move(pending.width) }
                return lock == .sideways
            }
            guard lock == .sideways else { return false }
            move(dx)
            return true
        }
    }
}
#endif
