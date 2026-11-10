import MailCore
import SwiftUI

/// The bar across the top of the window, right of the account rail: search in the middle (with
/// the Unread, Starred and Attachments toggles), and the one next thing on the right. Search
/// covers all mail, so it sits above every column rather than in the list.
struct WindowBar: View {
    @Bindable var model: MailModel
    var searchFocus: FocusState<Bool>.Binding

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: Space.s) {
            Spacer(minLength: Space.m)
                // A message that's been put away waits here, at the top left.
                .overlay(alignment: .leading) {
                    if model.isComposePutAway, let state = model.compose {
                        PutAwayDraftChip(model: model, state: state)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            MailSearchField(model: model, focus: searchFocus)
                .frame(maxWidth: 560)
            Spacer(minLength: Space.m)
                // The one next thing, at the top right: a meeting soon, or mail coming back. The
                // Next up column lists them all, so the badge steps aside while it shows.
                .overlay(alignment: .trailing) {
                    HStack(spacing: Space.s) {
                        if !model.isNextUpOnScreen { NextUpBadge(model: model) }
                        if model.layout == .panels {
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
            // The window has no title bar, so its empty space moves the window instead.
            Paper.sidebar.gesture(WindowDragGesture())
            #else
            Paper.sidebar
            #endif
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Line.hairline).frame(height: 1) }
    }
}

/// Search, with the quick filters at its end.
struct MailSearchField: View {
    @Bindable var model: MailModel
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
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
            if model.searchText.isEmpty { KeyCap("/") }
            // Minimal's Home stays calm: the greeting and group tabs take the place of filters.
            if !model.showsMinimalHome && model.layout != .spark {
                Rectangle().fill(Line.hairline).frame(width: 1, height: 14).padding(.horizontal, 2)
                QuickFilterToggles(model: model)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(Fill.one, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                    Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .medium))
                    Text(verbatim: title).font(TypeScale.label.weight(.medium)).lineLimit(1)
                }
                .foregroundStyle(Ink.primary)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(minHeight: touch ? 40 : 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Bring the message back"))
            .accessibilityLabel(Text("Bring back \(title)"))
            Button {
                model.closeComposer(state, isReply: isReply)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: touch ? 40 : 22, height: touch ? 40 : 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Save to Drafts and close"))
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
