import MailCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The bar across the top of the window, right of the account rail: search in the middle (with
/// the Unread, Starred and Attachments toggles), and the one next thing on the right. Search
/// covers all mail, so it sits above every column rather than in the list.
struct WindowBar: View {
    @Bindable var model: MailModel
    var searchFocus: FocusState<Bool>.Binding

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: Space.s) {
            // At least the room the window buttons and the sidebar button take, so search never
            // slides under them in a narrow window.
            Spacer(minLength: MailLayout.windowButtonsWidth + 34)
                // Right of the window buttons: the sidebar's button, where Mac apps keep it; then a
                // message that's been put away, waiting.
                .overlay(alignment: .leading) {
                    HStack(spacing: Space.s) {
                        if model.place != .calendar {
                            IconButton("sidebar.left", help: (model.sidebarNeedsDrawer ? !model.isSidebarDrawerOpen : model.isSidebarHidden)
                                       ? "Show sidebar  ⌃⌘S" : "Hide sidebar  ⌃⌘S") {
                                withAnimation(Motion.present) { model.toggleSidebar() }
                            }
                        }
                        if model.isComposePutAway, let state = model.compose {
                            PutAwayDraftChip(model: model, state: state)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.leading, MailLayout.windowButtonsWidth)
                }
            MailSearchField(model: model, focus: searchFocus)
                .frame(maxWidth: 560)
            Spacer(minLength: MailModel.nextUpAvailable && model.layout == .panels && !model.isWindowNarrow ? 34 : Space.m)
                // The one next thing, at the top right: a meeting soon, or mail coming back. The
                // Next up column lists them all, so the badge steps aside while it shows.
                .overlay(alignment: .trailing) {
                    HStack(spacing: Space.s) {
                        // Whether mail is up to date, and the Outbox while something waits to go.
                        if !model.outbox.isEmpty, !model.isWindowNarrow {
                            OutboxButton(model: model)
                        }
                        SyncStatusButton(model: model)
                        // In a narrow window there's no room for either beside search.
                        if MailModel.nextUpAvailable && !model.isNextUpOnScreen && !model.isWindowNarrow { NextUpBadge(model: model) }
                        if MailModel.nextUpAvailable && model.layout == .panels && !model.isWindowNarrow {
                            IconButton("sidebar.right", help: model.showsNextUp ? "Hide Next up" : "Show Next up") {
                                withAnimation(Motion.quick) { model.showsNextUp.toggle() }
                            }
                        }
                    }
                }
        }
        .padding(.horizontal, Space.m)
        .frame(height: Self.height)
        .background {
            #if os(macOS)
            // The window has no title bar, so the bar's empty space stands in for one: drag it
            // to move the window, double-click it for what System Settings says a title bar does.
            Paper.sidebar.overlay(TitleBarArea())
            #else
            Paper.sidebar
            #endif
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Line.hairline).frame(height: 1) }
    }
}

/// Whether mail is up to date: a quiet check mark, turning while mail is checked, a warning
/// when offline or a sign-in was refused. Click to check now; the pointer shows when it last did.
struct SyncStatusButton: View {
    let model: MailModel
    @State private var isHovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let line = model.statusLine(now: context.date).trimmingCharacters(in: .whitespaces)
            let trouble = model.isOffline || model.refusalNote != nil
            Button { Task { await model.reload() } } label: {
                Group {
                    if model.isLoading {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: trouble ? "exclamationmark.icloud" : "checkmark.icloud")
                            .font(.system(size: Look.size(13)))
                            .foregroundStyle(trouble ? Status.star : (isHovered ? Ink.secondary : Ink.tertiary))
                    }
                }
                .frame(width: 28, height: 28)
                .background(isHovered ? Fill.one : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(line.isEmpty ? Text("Up to date. Click to check for new mail.") : Text(verbatim: line))
            .accessibilityLabel(line.isEmpty ? Text("Up to date") : Text(verbatim: line))
        }
    }
}

/// The Outbox, while messages wait to be sent: how many, one click to see them.
struct OutboxButton: View {
    let model: MailModel

    var body: some View {
        Button { model.go(to: .scheduled) } label: {
            GlassChip(Text("Outbox"), symbol: "paperplane", count: model.outbox.count, isOn: model.place == .scheduled)
        }
        .buttonStyle(.plain)
        .help(Text("Messages waiting to be sent"))
    }
}

/// What a double-click on a title bar does, as chosen in System Settings → Desktop & Dock.
public enum TitleBarDoubleClick: Equatable, Sendable {
    case zoom, minimize, nothing

    /// From the system's two settings: `AppleActionOnDoubleClick` ("Maximize", "Fill", "Minimize"
    /// or "None"), and the older `AppleMiniaturizeOnDoubleClick` switch for when that isn't set.
    public static func action(setting: String?, legacyMinimize: Bool) -> TitleBarDoubleClick {
        switch setting {
        case "Minimize": .minimize
        case "None": .nothing
        case "Maximize", "Fill": .zoom
        default: legacyMinimize ? .minimize : .zoom
        }
    }

    /// Whether the double-click is still unanswered a moment later. Newer versions of macOS act
    /// on a double-click in this part of the window by themselves; doing it again on top would
    /// zoom the window and straight back. So Margin only acts when the window hasn't moved.
    public static func isUnanswered(before: CGRect, after: CGRect, isMiniaturized: Bool) -> Bool {
        !isMiniaturized && before == after
    }
}

#if os(macOS)
/// The empty part of the window bar, acting as the title bar the window doesn't have. It's a
/// plain AppKit view rather than SwiftUI's window-drag gesture, because that gesture only
/// started answering double-clicks in a later macOS: on the Macs before it, double-clicking the
/// bar did nothing. On the Macs that do answer by themselves, it leaves the double-click to them.
struct TitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TitleBarView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class TitleBarView: NSView {
        // The drag is started by hand below, so a double-click isn't swallowed by the system's own.
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            frameAtDoubleClick = window.frame
        }

        /// Where the window was when the second click went down.
        private var frameAtDoubleClick: CGRect?

        override func mouseUp(with event: NSEvent) {
            guard let before = frameAtDoubleClick else { return }
            frameAtDoubleClick = nil
            // The system gets a moment to answer first (it starts moving the window at once).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak window] in
                guard let window,
                      TitleBarDoubleClick.isUnanswered(before: before, after: window.frame, isMiniaturized: window.isMiniaturized) else { return }
                let defaults = UserDefaults.standard
                switch TitleBarDoubleClick.action(setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
                                                 legacyMinimize: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")) {
                case .zoom: window.performZoom(nil)
                case .minimize: window.performMiniaturize(nil)
                case .nothing: break
                }
            }
        }
    }
}
#endif

/// Search, with the quick filters at its end.
struct MailSearchField: View {
    @Bindable var model: MailModel
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Look.size(11)))
                .foregroundStyle(Ink.tertiary)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(TypeScale.row)
                .focused(focus)
                // Return searches everything: saved mail now, then every server.
                .onSubmit {
                    model.runSearch(model.searchText)
                    model.focusRequest += 1
                }
                .onKeyPress(.escape) {
                    model.searchText = ""
                    if case .search = model.place { model.go(to: .allInboxes) }
                    model.focusRequest += 1
                    return .handled
                }
                // ⌘↩ asks the assistant instead of searching, when it reads as a question.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command), model.offersAsk(for: model.searchText) else { return .ignored }
                    model.askFromSearch(model.searchText)
                    model.searchText = ""
                    return .handled
                }
            if model.searchText.isEmpty { KeyCap("/") }
            // Minimal's Home stays calm: the greeting and group tabs take the place of filters.
            if !model.showsMinimalHome && model.layout != .spark {
                Rectangle().fill(Line.hairline).frame(width: 1, height: 14).padding(.horizontal, 2)
                QuickFilterToggles(model: model)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: Look.gap(30))
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        // A question gets an offer under the field: the assistant answers it from your mail.
        .overlay(alignment: .topLeading) {
            if focus.wrappedValue, model.offersAsk(for: model.searchText) {
                Button {
                    model.askFromSearch(model.searchText)
                    model.searchText = ""
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: "sparkles").font(.system(size: Look.size(12))).foregroundStyle(Palette.accent)
                        Text("Ask: \(model.searchText.trimmingCharacters(in: .whitespaces))")
                            .font(TypeScale.row).foregroundStyle(Ink.primary).lineLimit(1)
                        Spacer(minLength: Space.s)
                        Text(verbatim: "⌘↩").font(TypeScale.label).foregroundStyle(Ink.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Look.gap(34))
                    .background(Paper.popover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Line.edge))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(y: 36)
                .transition(.opacity)
            }
        }
    }
}

/// A message that's been put away while you look at other mail: its subject (or who it's to)
/// in a small chip. Clicking brings it back down; the cross saves it to Drafts and closes it.
struct PutAwayDraftChip: View {
    let model: MailModel
    let state: ComposeState
    var isReply = false
    /// Bigger, for a finger.
    var touch = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(Motion.quick) {
                    if isReply { model.isReplyPutAway = false } else { model.isComposePutAway = false }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil").font(.system(size: Look.size(11), weight: .medium))
                    Text(verbatim: title).font(TypeScale.label.weight(.medium)).lineLimit(1)
                }
                .foregroundStyle(Ink.primary)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(minHeight: touch ? 40 : 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(Text("Bring the message back"))
            .accessibilityLabel(Text("Bring back \(title)"))
            Button {
                model.closeComposer(state, isReply: isReply)
            } label: {
                Image(systemName: "xmark").font(.system(size: Look.size(9), weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: touch ? 40 : 22, height: touch ? 40 : 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(Text("Save to Drafts and close"))
            .accessibilityLabel(Text("Save to Drafts and close"))
        }
        .padding(.trailing, 2)
        .background(Fill.one, in: Capsule())
        .overlay(Capsule().strokeBorder(Line.hairline))
        .frame(maxWidth: touch ? 320 : 240, alignment: .leading)
    }

    private var title: String {
        let subject = state.draft.subject.trimmingCharacters(in: .whitespaces)
        if !subject.isEmpty { return subject }
        let to = state.to.trimmingCharacters(in: .whitespaces)
        if !to.isEmpty { return String(localized: "To \(to)") }
        return String(localized: "New message")
    }
}
