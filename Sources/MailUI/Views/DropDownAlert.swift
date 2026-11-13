#if os(macOS)
import AppKit
import MailCore
import SwiftUI

/// A panel that can take typing (for a quick reply) without bringing Margin to the front.
private final class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// New mail at the top of the screen. On a Mac with a notch it drops out of the notch, black
/// like the notch itself; elsewhere it slides down under the menu bar. A sign-in code shows
/// big, already copied; a sign-in or confirmation link gets one Open button; other mail can be
/// answered right there. It goes away by itself unless you're using it.
@MainActor
final class DropDownAlertWindow {
    static let shared = DropDownAlertWindow()
    private var panel: AlertPanel?
    private var hideTask: Task<Void, Never>?

    /// Whether the main screen has a notch, and how wide it is.
    static var notchWidth: CGFloat? {
        guard let screen = NSScreen.main, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return right.minX - left.maxX
    }

    func show(_ thread: MailThread, model: MailModel) {
        hideTask?.cancel()
        let fromNotch = Self.notchWidth != nil
        let view = DropDownAlertView(thread: thread, model: model, fromNotch: fromNotch) { [weak self] in
            self?.hide()
        } keepOpen: { [weak self] in
            self?.hideTask?.cancel()
            self?.panel?.makeKey()
        }
        let hosting = NSHostingView(rootView: view)
        let panel = self.panel ?? AlertPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the menu bar when it comes out of the notch.
        panel.level = fromNotch ? .popUpMenu : .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = !fromNotch
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        guard let screen = NSScreen.main else { return }
        let size = hosting.fittingSize
        let width = max(size.width, 420)
        let top = fromNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let target = NSRect(x: screen.frame.midX - width / 2, y: top - size.height, width: width, height: size.height)
        // It grows out of the notch, or slides down from behind the menu bar.
        let start = fromNotch
            ? NSRect(x: screen.frame.midX - (Self.notchWidth ?? 200) / 2, y: top - 32, width: Self.notchWidth ?? 200, height: 32)
            : target.offsetBy(dx: 0, dy: size.height)
        panel.setFrame(start, display: false)
        panel.alphaValue = fromNotch ? 1 : 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = model.reduceMotion ? 0 : 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        let notch = Self.notchWidth
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            if let notch, let screen = NSScreen.main {
                panel.animator().setFrame(NSRect(x: screen.frame.midX - notch / 2, y: screen.frame.maxY - 32, width: notch, height: 32), display: true)
            }
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private struct DropDownAlertView: View {
    let thread: MailThread
    let model: MailModel
    let fromNotch: Bool
    let close: () -> Void
    let keepOpen: () -> Void
    @State private var replying = false
    @State private var text = ""
    @State private var sending = false
    @State private var link: (url: URL, kind: SignInLink.Kind)?
    @State private var copied = false
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL

    private var code: String? { model.signInCode(in: thread) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if fromNotch { Color.clear.frame(height: Look.gap(26)) } // the notch itself
            HStack(alignment: .top, spacing: Space.s) {
                Avatar(thread.latest.from, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: thread.latest.from.displayName).font(TypeScale.rowStrong).foregroundStyle(primary).lineLimit(1)
                    Text(verbatim: thread.subject).font(TypeScale.row).foregroundStyle(primary).lineLimit(1)
                    if code == nil {
                        Text(verbatim: thread.latest.snippet).font(TypeScale.label).foregroundStyle(secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            if let code {
                // The code, big, already on the clipboard.
                HStack {
                    Text(verbatim: ReaderSuggestion.spaced(code)).font(.system(size: Look.size(26), weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(primary).textSelection(.enabled)
                    Spacer()
                    Button(copied || model.copiesSignInCodes ? String(localized: "Copied") : String(localized: "Copy")) {
                        MailModel.putOnPasteboard(code)
                        copied = true
                    }
                    .buttonStyle(prominentStyle)
                }
            } else if let link {
                Button {
                    openURL(link.url)
                    close()
                } label: {
                    Label(link.kind == .confirm ? String(localized: "Confirm in the browser") : String(localized: "Sign in in the browser"),
                          systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(prominentStyle)
                .tip(link.url.host() ?? "")
            }
            if replying {
                HStack(spacing: Space.s) {
                    TextField("Quick reply", text: $text, axis: .vertical)
                        .fieldStyle().lineLimit(1...4).focused($focused).onSubmit(send)
                    Button("Send", action: send).buttonStyle(prominentStyle).disabled(text.isEmpty || sending)
                }
            }
            HStack(spacing: Space.s) {
                Button("Open") {
                    NSApp.activate()
                    model.reveal(thread.id)
                    close()
                }
                .buttonStyle(quietStyle)
                if !replying && code == nil && link == nil {
                    Button("Reply") { replying = true; keepOpen(); focused = true }.buttonStyle(quietStyle)
                }
                Spacer()
                Button("Dismiss", action: close).buttonStyle(quietStyle)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.top, fromNotch ? 0 : Space.m)
        .padding(.bottom, Space.m)
        .frame(width: 420)
        .background(background)
        .tint(Ink.primary)
        .environment(\.colorScheme, fromNotch ? .dark : model.appearance.colorScheme ?? .light)
        .onHover { if $0 { keepOpen() } }
        .task {
            // The body may not be here yet: load it, then look for a sign-in link.
            await model.loadAllBodies(of: thread)
            link = model.signInLink(in: thread)
        }
    }

    @ViewBuilder
    private var background: some View {
        if fromNotch {
            // Black like the notch: square at the top where it joins the screen edge, round below.
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous).fill(.black)
        } else {
            RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Paper.popover)
                .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Line.edge))
        }
    }

    private var primary: Color { fromNotch ? .white : Ink.primary }
    private var secondary: Color { fromNotch ? .white.opacity(0.6) : Ink.tertiary }
    private var prominentStyle: some PrimitiveButtonStyle { .borderedProminent }
    private var quietStyle: some PrimitiveButtonStyle { .bordered }

    private func send() {
        guard !text.isEmpty else { return }
        sending = true
        Task {
            if await model.quickReply(to: thread.id, text: text) { close() }
            sending = false
        }
    }
}
#endif
