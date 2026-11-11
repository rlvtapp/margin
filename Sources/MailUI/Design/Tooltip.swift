import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Margin's tooltips: a small label under what the pointer rests on, a quarter of a second after it
/// arrives. The system's tooltips didn't show in Margin's title-bar-less window, so these are
/// drawn in a little floating window of their own, above everything, on the Mac. On iPhone and
/// iPad they're the system's (pointer and long-press).
/// Where a tip opens: under what it's about, or to its right (for the column at the window's
/// left edge, where a tip underneath would cover the next button).
public enum TipSide: Sendable { case below, right }

extension View {
    public func tip(_ text: Text, side: TipSide = .below) -> some View {
        #if os(macOS)
        modifier(TipModifier(text: text, side: side)).accessibilityHint(text)
        #else
        help(text)
        #endif
    }

    public func tip(_ key: LocalizedStringKey, side: TipSide = .below) -> some View {
        tip(Text(key), side: side)
    }

    @_disfavoredOverload
    public func tip<S: StringProtocol>(_ string: S, side: TipSide = .below) -> some View {
        tip(Text(string), side: side)
    }
}

#if os(macOS)
private struct TipModifier: ViewModifier {
    let text: Text
    let side: TipSide
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(TipAnchor(text: text, side: side, shown: shown))
            .onHover { inside in
                pending?.cancel()
                guard inside else { shown = false; return }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    shown = true
                    // Not forever: a label left behind is in the way.
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    shown = false
                }
            }
            .onDisappear {
                pending?.cancel()
                shown = false
            }
    }
}

/// Where the tip belongs: a plain view behind the content, so the floating label can be placed
/// under it on screen.
private struct TipAnchor: NSViewRepresentable {
    let text: Text
    let side: TipSide
    let shown: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        if shown {
            TipWindow.shared.show(text, by: view, side: side)
        } else {
            TipWindow.shared.hide(for: view)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        TipWindow.shared.hide(for: view)
    }
}

/// The one floating window every tip uses: borderless, never takes focus, and lets clicks
/// through.
@MainActor
private final class TipWindow {
    static let shared = TipWindow()
    fileprivate weak var owner: NSView?

    fileprivate let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }()

    /// A click, a drag or a scroll puts the tip away at once; while a button is held, none shows.
    private lazy var monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .rightMouseDown, .scrollWheel]) { event in
        MainActor.assumeIsolated {
            TipWindow.shared.panel.orderOut(nil)
            TipWindow.shared.owner = nil
        }
        return event
    }

    func show(_ text: Text, by view: NSView, side: TipSide) {
        _ = monitor
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let host = NSHostingView(rootView: TipBubble(text: text).environment(\.colorScheme, dark ? .dark : .light))
        let size = host.fittingSize
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let visible = screen.visibleFrame
        var origin: NSPoint
        switch side {
        case .right:
            origin = NSPoint(x: anchor.maxX - 2, y: anchor.midY - size.height / 2)
        case .below:
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height + 2)
            // No room under it (the bottom of the screen): above instead.
            if origin.y < visible.minY { origin.y = anchor.maxY - 2 }
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.contentView = host
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        owner = view
    }

    func hide(for view: NSView) {
        guard owner === view else { return }
        panel.orderOut(nil)
        owner = nil
    }
}

/// The label itself: small text on the popover colour, with a hairline and a soft shadow.
private struct TipBubble: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Ink.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Paper.popover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Line.edge))
            .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
            .padding(8)
            .fixedSize()
    }
}
#endif
