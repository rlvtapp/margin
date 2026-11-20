import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The arithmetic behind sliding and zooming the Day and Week grid, kept apart so it can be tested.
enum CalendarScroll {
    /// Letting go mid-slide: the days lock onto a whole column, the one the swipe was heading
    /// for (where it would coast to at `velocity`, points per step), else the nearer one. Returns
    /// the days to move and the slide left over (which then springs to zero).
    static func settle(slide: CGFloat, column: CGFloat, velocity: CGFloat = 0) -> (days: Int, slide: CGFloat) {
        guard column > 0 else { return (0, 0) }
        let heading = slide + velocity * 10
        let days = Int((-heading / column).rounded())
        return (days, slide + CGFloat(days) * column)
    }

    /// Below this speed (points per scroll event) a coasting swipe stops coasting and locks on,
    /// instead of drifting to a halt and then jumping.
    static let lockSpeed: CGFloat = 6

    /// Up to a week the fingers move the days freely; past it they stretch a little, like a
    /// rubber band, and the days spring back to the week.
    static func resisted(_ dx: CGFloat, travel: CGFloat, cap: CGFloat) -> CGFloat {
        guard cap > 0 else { return 0 }
        // Moving back towards the start is never held back.
        if travel * dx <= 0 { return dx }
        let free = max(cap - abs(travel), 0)
        let inside = min(abs(dx), free)
        let beyond = abs(dx) - inside
        return (inside + beyond * 0.15) * (dx < 0 ? -1 : 1)
    }

    /// How far ahead a swipe's speed carries it when the fingers lift, in seconds of that
    /// speed: where it would come to rest if left to glide.
    static let projection: CGFloat = 0.35

    /// Where a swipe lands, as days moved all told, decided the moment the fingers lift.
    /// It's projected from how far the fingers moved the days (`travel`) and how fast they were
    /// going (`speed`, points a second). In Week, heading past half a week lands on the first
    /// day of the next or previous week (`daysToWeekStart`, from where the swipe began);
    /// otherwise on the nearer day, so a gentle swipe moves a day or two.
    static func swipeDays(travel: CGFloat, speed: CGFloat, column: CGFloat, days count: Int,
                          daysToWeekStart: (next: Int, previous: Int)? = nil) -> Int {
        guard column > 0, count > 0 else { return 0 }
        let heading = travel + speed * projection
        let cap = CGFloat(count) * column
        if count > 1, abs(heading) >= cap * 0.5 {
            let forward = heading < 0
            if let weeks = daysToWeekStart { return forward ? weeks.next : weeks.previous }
            return forward ? count : -count
        }
        return max(min(Int((-heading / column).rounded()), count), -count)
    }

    /// From a week's first shown day: how many days to the first day of the next week and of
    /// the previous one (the region's first weekday), so a locked swipe lands on a real week.
    static func daysToWeekStart(from day: Date, calendar: Calendar = .current) -> (next: Int, previous: Int) {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        let behind = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: day)).day ?? 0
        return (7 - behind, behind == 0 ? -7 : -behind)
    }

    /// One frame of a critically damped spring pulling `offset` to zero: no overshoot, and soft,
    /// with about half a second to come to rest. Small steps keep it steady at any frame rate.
    static let springOmega: CGFloat = 2 * .pi / 0.5

    static func springStep(offset: CGFloat, velocity: CGFloat, dt: Double) -> (offset: CGFloat, velocity: CGFloat) {
        let omega = springOmega
        var x = offset, v = velocity
        let steps = 4
        let h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps {
            let a = -omega * omega * x - 2 * omega * v
            v += a * h
            x += v * h
        }
        return (x, v)
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
    /// A new sideways swipe has begun.
    let start: () -> Void
    let move: (CGFloat) -> Void
    /// Locks on, given the last speed (points per scroll event).
    let end: (CGFloat) -> Void
    let step: (Int) -> Void

    func makeNSView(context: Context) -> ScrollerView {
        let view = ScrollerView()
        update(view)
        return view
    }

    func updateNSView(_ view: ScrollerView, context: Context) { update(view) }

    private func update(_ view: ScrollerView) {
        view.start = start
        view.move = move
        view.end = end
        view.step = step
    }

    final class ScrollerView: NSView {
        var start: () -> Void = {}
        var move: (CGFloat) -> Void = { _ in }
        var end: (CGFloat) -> Void = { _ in }
        var step: (Int) -> Void = { _ in }
        private var monitor: Any?
        /// How much of the trackpad's momentum a coasting swipe keeps.
        static let coast: CGFloat = 0.6
        /// `settled`: the days already locked on; the rest of the swipe's momentum is used up.
        private enum Lock { case sideways, upDown, settled }
        private var lastDX: CGFloat = 0
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
                let over = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
                if lock == .settled {
                    if over { lock = nil }
                    return true
                }
                guard lock == .sideways else { return false }
                waitingForMomentum = false
                if over {
                    lock = nil
                    end(lastDX)
                } else if abs(dx) < CalendarScroll.lockSpeed {
                    // Slow enough: lock on now, carrying the last of the speed.
                    lock = .settled
                    end(dx)
                } else {
                    // Coasting carries less than the fingers did, as in Apple's calendars.
                    lastDX = dx * Self.coast
                    move(dx * Self.coast)
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
                // The fingers lifted: where it lands is decided now, and the system's momentum
                // that follows is used up here, so the glide is one smooth movement.
                lock = .settled
                end(lastDX)
                return true
            }
            if lock == .settled { lock = nil }
            if lock == nil {
                pending.width += dx
                pending.height += dy
                guard abs(pending.width) + abs(pending.height) > 3 else { return true }
                lock = abs(pending.width) > abs(pending.height) ? .sideways : .upDown
                if lock == .sideways {
                    start()
                    move(pending.width)
                }
                return lock == .sideways
            }
            guard lock == .sideways else { return false }
            lastDX = dx
            move(dx)
            return true
        }
    }
}
#endif
