import MailCore
import SwiftUI

extension MailModel {
    /// Done, read or unread, and Trash on a list row while the pointer is over it (Mac).
    public var showsHoverActions: Bool {
        get { _ = alertRevision; return environment.defaults.object(forKey: "showsHoverActions") as? Bool ?? true }
        set {
            guard newValue != showsHoverActions else { return }
            environment.defaults.set(newValue, forKey: "showsHoverActions")
            alertRevision += 1
        }
    }
}

extension MailModel {
    /// Asks before sending a message that mentions an attachment but has none.
    public var remindsAboutAttachments: Bool {
        get { _ = alertRevision; return environment.defaults.object(forKey: "remindsAboutAttachments") as? Bool ?? true }
        set {
            guard newValue != remindsAboutAttachments else { return }
            environment.defaults.set(newValue, forKey: "remindsAboutAttachments")
            alertRevision += 1
        }
    }
}

/// Whether a row is swiped aside, with its swipe actions showing.
struct RowSwipeIsOpen: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Buttons at the end of a row while the pointer is over it, so the common things need no
/// opening, menu or keyboard.
struct RowHoverActions: ViewModifier {
    let model: MailModel
    let thread: MailThread
    @State private var isHovered = false
    /// The row is swiped aside: its swipe actions are in the same place, so the buttons wait.
    @State private var isSwiped = false

    func body(content: Content) -> some View {
        // Hover is tracked over the row and its buttons together: tracked on the row alone,
        // moving onto a button counted as leaving the row, and the buttons vanished.
        let shows = isHovered && !isSwiped && model.showsHoverActions && model.selection.isEmpty
        content
            .overlay(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                if shows {
                    HStack(spacing: 2) {
                        button("checkmark.circle", help: "Done") { model.perform(.done, on: thread) }
                        button(thread.isUnread ? "envelope.open" : "envelope.badge", help: thread.isUnread ? "Mark read" : "Mark unread") {
                            model.perform(thread.isUnread ? .markRead : .markUnread, on: thread)
                        }
                        button("trash", help: "Move to Trash") { model.perform(.trash, on: thread) }
                    }
                    .padding(2)
                    .background(Paper.panel, in: Capsule())
                    .overlay(Capsule().strokeBorder(Line.edge))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                    .padding(.trailing, Space.s)
                    // Eased in and out, a little from the edge, so they don't pop over the row
                    // or snap away when a swipe starts.
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)).combined(with: .offset(x: 6)))
                }
                }
                // On the buttons alone, so nothing else in the row eases with them.
                .animation(Look.reduceMotion ? nil : .easeOut(duration: 0.18), value: shows)
            }
            .onPreferenceChange(RowSwipeIsOpen.self) { open in
                if open != isSwiped { isSwiped = open }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: if !isHovered { isHovered = true }
                case .ended: isHovered = false
                }
            }
    }

    private func button(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        IconButton(symbol, help: help, action: action)
    }
}

extension View {
    func rowHoverActions(model: MailModel, thread: MailThread) -> some View {
        #if os(macOS)
        modifier(RowHoverActions(model: model, thread: thread))
        #else
        self
        #endif
    }
}
