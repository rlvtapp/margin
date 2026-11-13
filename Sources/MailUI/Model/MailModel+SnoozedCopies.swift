import Foundation
import MailCore

/// Snoozed shows every snoozed conversation at once, also ones older than the inbox mail kept
/// in memory: a copy of each is saved when it's snoozed (without message text, which is saved
/// elsewhere) and dropped when it wakes or is unsnoozed. The inbox's own copy wins when it has one.
extension MailModel {
    /// One saved conversation: its messages and mailbox.
    struct SnoozedCopy: Codable {
        var id: String
        var accountID: UUID?
        var messages: [MailMessage]
    }

    private static func copiesFile(_ folder: URL) -> JSONFile<[String: SnoozedCopy]> {
        JSONFile(url: folder.appending(path: "snoozed-conversations.json"))
    }

    static func loadSnoozedCopies(from folder: URL) -> [String: MailThread] {
        (copiesFile(folder).load() ?? [:]).mapValues { MailThread(id: $0.id, messages: $0.messages, accountID: $0.accountID) }
    }

    func saveSnoozedCopies() {
        guard !environment.isPreview else { return }
        let copies = snoozedCopies.mapValues { thread in
            SnoozedCopy(id: thread.id, accountID: thread.accountID, messages: thread.messages.map { message in
                var light = message
                light.body = nil
                return light
            })
        }
        Self.copiesFile(environment.folder).save(copies)
    }

    /// Snoozed conversations that are in the inboxes now, kept as copies too (also ones snoozed
    /// before copies were kept). Written only when something changed.
    func rememberSnoozedCopies() {
        var changed = false
        for (thread, _) in snoozedInInboxes(nil) {
            let key = LabelStore.key(for: thread)
            if snoozedCopies[key]?.latest.id != thread.latest.id || snoozedCopies[key]?.messages.count != thread.messages.count {
                snoozedCopies[key] = thread
                changed = true
            }
        }
        if changed { saveSnoozedCopies() }
    }

    /// Everything snoozed in one mailbox or (nil) all of them, newest first: the inbox's
    /// conversations, and saved copies of the ones not in memory.
    func snoozedConversations(_ accountID: UUID?) -> [MailThread] {
        let now = Date()
        var byKey: [String: MailThread] = [:]
        for (key, until) in snoozes where until > now {
            if let copy = snoozedCopies[key] { byKey[key] = copy }
        }
        for (thread, _) in snoozedInInboxes(accountID) { byKey[LabelStore.key(for: thread)] = thread }
        return byKey.values
            .filter { accountID == nil || $0.accountID == accountID }
            .filter { thread in self.account(thread.accountID) != nil }
            .sorted { $0.date > $1.date }
    }
}
