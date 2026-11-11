import MailCore
import SwiftUI
#if os(macOS)
import AppKit

/// Two fingers sideways on a trackpad over a conversation, as in the Mac's own Mail: the row
/// follows the fingers and shows the actions behind it (Settings → Appearance → Swipes). Let go
/// part of the way and the row stays open so an action can be clicked; swipe on past the
/// actions and the first one runs. Scrolling up and down is left alone.
extension View {
    func rowSwipe(model: MailModel, thread: MailThread) -> some View {
        modifier(RowSwipe(model: model, thread: thread))
    }
}

private struct RowSwipe: ViewModifier {
    let model: MailModel
    let thread: MailThread
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    @State private var pastFull = false

    private static let tile: CGFloat = 80

    private var leading: [SwipeAction] { model.leadingSwipes.filter { $0 != .none } }
    private var trailing: [SwipeAction] { model.trailingSwipes.filter { $0 != .none } }
    private var openLeading: CGFloat { CGFloat(leading.count) * Self.tile }
    private var openTrailing: CGFloat { CGFloat(trailing.count) * Self.tile }
    /// How far a swipe goes before the first action runs on letting go.
    private var fullDistance: CGFloat { max(width * 0.45, max(openLeading, openTrailing) + 70) }

    func body(content: Content) -> some View {
        content
            // Solid while it moves, so the actions don't show through the row's text.
            .background(offset != 0 ? Paper.panel : .clear)
            .offset(x: offset)
            .background(alignment: .leading) {
                if offset > 0 { actions(leading, edge: .leading).frame(width: offset) }
            }
            .background(alignment: .trailing) {
                if offset < 0 { actions(trailing, edge: .trailing).frame(width: -offset) }
            }
            .background { SwipeCatcher(began: began, changed: changed, ended: ended) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // A click on an open row closes it instead of opening the conversation.
            .overlay {
                if offset != 0 {
                    Color.clear.contentShape(Rectangle())
                        .offset(x: offset)
                        .onTapGesture { close() }
                }
            }
            .onChange(of: thread.id) { _, _ in offset = 0 }
    }

    /// The actions on one side, sharing the uncovered space and growing into it; past the full
    /// distance the first one stretches over all of it while the others shrink away.
    private func actions(_ list: [SwipeAction], edge: HorizontalEdge) -> some View {
        let revealed = abs(offset)
        let ordered = edge == .leading ? list : Array(list.reversed())
        let share = revealed / CGFloat(max(list.count, 1))
        return HStack(spacing: 0) {
            ForEach(ordered) { action in
                let isFirst = action == list.first
                let tileWidth = pastFull ? (isFirst ? revealed : 0) : share
                SwipeTile(action: action, thread: thread, width: tileWidth, stretched: pastFull && isFirst) { run(action) }
                    .frame(width: tileWidth)
                    .opacity(pastFull && !isFirst ? 0 : 1)
            }
        }
        .frame(width: revealed, alignment: edge == .leading ? .leading : .trailing)
        .clipped()
    }

    private func began() {
        startOffset = offset
    }

    private func changed(_ distance: CGFloat) {
        var next = startOffset + distance
        if leading.isEmpty { next = min(next, 0) }
        if trailing.isEmpty { next = max(next, 0) }
        // Past the end it gets heavier, so the edge is felt.
        let limit = width * 0.85
        if abs(next) > limit { next = (next > 0 ? 1 : -1) * (limit + (abs(next) - limit) * 0.2) }
        // A light interactive spring evens out the trackpad's uneven steps.
        withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.9)) { offset = next }
        let past = abs(next) > fullDistance
        if past != pastFull {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { pastFull = past }
        }
    }

    private func ended() {
        let list = offset > 0 ? leading : trailing
        if pastFull, let first = list.first {
            run(first)
            return
        }
        let open = offset > 0 ? openLeading : openTrailing
        let staysOpen = abs(offset) > open * 0.5
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            offset = staysOpen ? (offset > 0 ? open : -open) : 0
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            offset = 0
            pastFull = false
        }
    }

    private func run(_ action: SwipeAction) {
        // Done, Trash and Snooze take the conversation away: it slides off first.
        let removes = action == .done || action == .trash || action == .snooze
        guard removes, width > 0 else { perform(action); return }
        let away = offset >= 0 ? width : -width
        withAnimation(.easeIn(duration: 0.16)) { offset = away }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            perform(action)
            offset = 0
            pastFull = false
        }
    }

    private func perform(_ action: SwipeAction) {
        switch action {
        case .done: model.perform(.done, on: thread)
        case .trash: model.perform(.trash, on: thread)
        case .star: model.perform(thread.isStarred ? .unstar : .star, on: thread)
        case .read: model.perform(thread.isUnread ? .markRead : .markUnread, on: thread)
        case .snooze: model.snooze(thread, until: SnoozePreset.tomorrow.date())
        case .none: break
        }
        close()
    }
}

/// One action behind a row: a coloured capsule with its symbol, and its name under it. Stretched,
/// the capsule fills the width it has.
private struct SwipeTile: View {
    let action: SwipeAction
    let thread: MailThread
    /// The room it has: it grows into it, from small and faint to full size.
    var width: CGFloat = 80
    var stretched = false
    let run: () -> Void

    private var grown: CGFloat { min(1, max(0, width / 80)) }

    var body: some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: stretched ? max(58, width - 28) : 58, height: 32)
                    .background(color, in: Capsule())
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            .scaleEffect(0.55 + 0.45 * grown)
            .opacity(Double(min(1, max(0, (width - 14) / 46))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        switch action {
        case .done: String(localized: "Done")
        case .trash: String(localized: "Trash")
        case .star: thread.isStarred ? String(localized: "Unstar") : String(localized: "Star")
        case .read: thread.isUnread ? String(localized: "Read") : String(localized: "Unread")
        case .snooze: String(localized: "Snooze")
        case .none: ""
        }
    }

    private var symbol: String {
        switch action {
        case .done: "checkmark"
        case .trash: "trash"
        case .star: thread.isStarred ? "star.slash.fill" : "star.fill"
        case .read: thread.isUnread ? "envelope.open.fill" : "envelope.badge.fill"
        case .snooze: "clock.fill"
        case .none: ""
        }
    }

    private var color: Color { action.color }
}

/// Watches the trackpad for a sideways two-finger swipe that starts over this row, and keeps
/// it from scrolling the list; anything mostly up and down passes through untouched.
private struct SwipeCatcher: NSViewRepresentable {
    let began: () -> Void
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.began = began
        view.changed = changed
        view.ended = ended
    }

    final class CatcherView: NSView {
        var began: () -> Void = {}
        var changed: (CGFloat) -> Void = { _ in }
        var ended: () -> Void = {}
        private var monitor: Any?
        private var tracking = false
        /// nil until the swipe has moved enough to tell sideways from up and down.
        private var sideways: Bool?
        private var total = CGSize.zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let event = event
                let keep = MainActor.assumeIsolated { self?.takes(event) ?? false }
                return keep ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Whether this row keeps the event (a sideways swipe over it) instead of the list.
        private func takes(_ event: NSEvent) -> Bool {
            guard event.window === window, event.hasPreciseScrollingDeltas else { return false }
            // The coasting after the fingers lift belongs to whoever had the swipe.
            if event.momentumPhase != [] { return tracking == false && sideways == true }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                tracking = bounds.contains(convert(event.locationInWindow, from: nil))
                sideways = nil
                total = .zero
                if tracking { began() }
                return false
            }
            guard tracking else { return false }
            if event.phase.contains(.changed) {
                // Content follows the fingers whichever way the scroll direction is set.
                let flip: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
                total.width += event.scrollingDeltaX * flip
                total.height += event.scrollingDeltaY
                if sideways == nil, hypot(total.width, total.height) > 6 {
                    sideways = abs(total.width) > abs(total.height) * 1.4
                }
                guard sideways == true else { return false }
                changed(total.width)
                return true
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                tracking = false
                guard sideways == true else { return false }
                ended()
                return true
            }
            return false
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
#else
extension View {
    func rowSwipe(model: MailModel, thread: MailThread) -> some View { self }
}
#endif

