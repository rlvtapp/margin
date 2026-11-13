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

/// Buttons at the end of a row while the pointer is over it, so the common things need no
/// opening, menu or keyboard.
struct RowHoverActions: ViewModifier {
    let model: MailModel
    let thread: MailThread
    @State private var isHovered = false

    func body(content: Content) -> some View {
        // Hover is tracked over the row and its buttons together: tracked on the row alone,
        // moving onto a button counted as leaving the row, and the buttons vanished.
        content
            .overlay(alignment: .trailing) {
                if isHovered && model.showsHoverActions && model.selection.isEmpty {
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
                    .transition(.opacity)
                }
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
