import MailCore
import SwiftUI

extension MailModel {
    /// Conversations shown as a chat: each message a bubble, quoted history left out.
    public var showsAsChat: Bool {
        get { _ = alertRevision; return environment.defaults.bool(forKey: "showsAsChat") }
        set { environment.defaults.set(newValue, forKey: "showsAsChat"); alertRevision += 1 }
    }

    /// Whether a message was written by the person, from any of their addresses.
    func isMine(_ message: MailMessage) -> Bool {
        let address = message.from.address.lowercased()
        return accounts.contains { $0.sendAddresses.contains { $0.address.lowercased() == address } }
    }
}

/// A conversation as a chat: the person's own messages on the right, others on the left with
/// their name, each showing only what was newly written.
struct ChatConversationView: View {
    let model: MailModel
    let thread: MailThread
    @Environment(\.mailAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(thread.messages.enumerated()), id: \.element.id) { index, message in
                let mine = model.isMine(message)
                let previous = index > 0 ? thread.messages[index - 1] : nil
                let sameSender = previous.map { $0.from.address.lowercased() == message.from.address.lowercased() } ?? false
                VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                    if !sameSender {
                        HStack(spacing: Space.xs) {
                            if !mine { Text(verbatim: message.from.displayName).font(TypeScale.label.weight(.medium)).foregroundStyle(Ink.secondary) }
                            Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(TypeScale.caption).foregroundStyle(Ink.tertiary)
                        }
                        .padding(.top, index == 0 ? 0 : Space.s)
                    }
                    Text(verbatim: text(of: message))
                        .font(TypeScale.body.leading(.loose))
                        .foregroundStyle(mine ? Color.white : Ink.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(mine ? accent : Fill.one, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: 560, alignment: mine ? .trailing : .leading)
                    let files = model.body(of: message, in: thread)?.attachments ?? []
                    if !files.isEmpty {
                        Text(verbatim: files.map { "📎 " + $0.filename }.joined(separator: "  "))
                            .font(TypeScale.label).foregroundStyle(Ink.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                .id(message.id)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    private func text(of message: MailMessage) -> String {
        let full = model.body(of: message, in: thread)?.text ?? message.snippet
        let own = WritingProfile.ownWriting(full, signature: model.account(thread.accountID)?.signature)
        return own.isEmpty ? message.snippet : own
    }
}
