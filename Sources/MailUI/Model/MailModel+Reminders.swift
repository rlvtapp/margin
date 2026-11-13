import Foundation
import MailCore
#if canImport(EventKit)
import EventKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A sent message to check on later: if nobody answered by then, you're reminded.
struct ReplyReminder: Codable, Hashable, Identifiable {
    var id = UUID()
    var accountID: UUID
    var recipients: [String]
    var subject: String
    var sentAt: Date
    var remindAt: Date
}

extension MailModel {
    private var reminderFile: JSONFile<[ReplyReminder]> { JSONFile(url: environment.folder.appending(path: "reply-reminders.json")) }

    var replyReminders: [ReplyReminder] {
        get {
            if let replyReminderStore { return replyReminderStore }
            let loaded = environment.isPreview ? [] : (reminderFile.load() ?? [])
            replyReminderStore = loaded
            return loaded
        }
        set {
            replyReminderStore = newValue
            if !environment.isPreview { reminderFile.save(newValue) }
        }
    }

    /// Called after a message with a reminder was sent.
    func remindIfNoReply(_ draft: Draft, accountID: UUID, after days: Int) {
        let now = Date()
        replyReminders.append(ReplyReminder(
            accountID: accountID, recipients: (draft.to + draft.cc).map { $0.address.lowercased() },
            subject: Subject.normalized(draft.subject), sentAt: now,
            remindAt: Calendar.current.date(byAdding: .day, value: days, to: now) ?? now.addingTimeInterval(Double(days) * 86_400)
        ))
    }

    /// Whether anyone the message went to wrote back on the same subject after it was sent.
    func gotReply(to reminder: ReplyReminder) -> Bool {
        let people = Set(reminder.recipients)
        return inboxThreads(nil).contains { thread in
            Subject.normalized(thread.subject) == reminder.subject
                && thread.messages.contains { $0.date > reminder.sentAt && people.contains($0.from.address.lowercased()) }
        }
    }

    /// From the clock: reminders that are due either go quietly (there was a reply) or alert.
    func checkReplyReminders(now: Date = Date()) {
        let due = replyReminders.filter { $0.remindAt <= now }
        guard !due.isEmpty else { return }
        replyReminders.removeAll { item in due.contains { $0.id == item.id } }
        for reminder in due where !gotReply(to: reminder) {
            let who = reminder.recipients.first ?? ""
            notice = Notice(text: String(localized: "No reply yet from \(who): \(reminder.subject)"))
            #if canImport(UserNotifications)
            guard !environment.isPreview else { continue }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "No reply yet")
            content.body = "\(reminder.subject) · \(who)"
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "reply-\(reminder.id)", content: content, trigger: nil))
            #endif
        }
    }

    // MARK: Add to Reminders

    /// Makes a reminder in the Reminders app for a conversation, with a link back to it.
    public func addToReminders(_ thread: MailThread) {
        #if canImport(EventKit)
        let store = EKEventStore()
        Task {
            do {
                guard try await store.requestFullAccessToReminders() else {
                    notice = Notice(text: String(localized: "Allow Margin to use Reminders in System Settings → Privacy."), isError: true)
                    return
                }
                let reminder = EKReminder(eventStore: store)
                reminder.title = thread.subject.isEmpty ? thread.latest.from.displayName : thread.subject
                reminder.notes = String(localized: "From \(thread.latest.from.displayName)") + "\n" + thread.latest.snippet
                reminder.url = Self.link(to: thread)
                reminder.calendar = store.defaultCalendarForNewReminders()
                try store.save(reminder, commit: true)
                addLabel(String(localized: "Tasks"), to: thread)
                notice = Notice(text: String(localized: "Added to Reminders"))
            } catch {
                show(error)
            }
        }
        #endif
    }

    /// A link that opens a conversation in Margin: margin://message/<first Message-ID>.
    static func link(to thread: MailThread) -> URL? {
        let id = thread.messages.first?.messageID ?? thread.id
        var components = URLComponents()
        components.scheme = "margin"
        components.host = "message"
        components.path = "/" + id
        return components.url
    }

    /// Opens a margin://message/<id> link.
    func openMessageLink(_ url: URL) -> Bool {
        guard url.scheme == "margin", url.host() == "message" else { return false }
        let id = String(url.path().dropFirst())
        guard let thread = inboxThreads(nil).first(where: { $0.messages.first?.messageID == id || $0.id == id }) else {
            notice = Notice(text: String(localized: "That conversation isn't in the inbox anymore. Search for it to find it."))
            return true
        }
        reveal(thread.id)
        return true
    }
}

/// While writing: remind me if nobody answers.
struct ReplyReminderMenu: View {
    @Binding var state: ComposeState

    var body: some View {
        Menu {
            Button { state.remindAfterDays = nil } label: { choice("Don't remind me", nil) }
            Button { state.remindAfterDays = 1 } label: { choice("If no reply by tomorrow", 1) }
            Button { state.remindAfterDays = 3 } label: { choice("If no reply in 3 days", 3) }
            Button { state.remindAfterDays = 7 } label: { choice("If no reply in a week", 7) }
        } label: {
            // A quiet icon like the other writing tools; filled while a reminder is set.
            Image(systemName: state.remindAfterDays == nil ? "alarm" : "alarm.fill")
                .font(.system(size: Look.size(12.5)))
                .foregroundStyle(state.remindAfterDays == nil ? Ink.tertiary : Ink.primary)
                .frame(width: 28, height: 28)
                .accessibilityLabel(Text("Remind me"))
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .tip("Remind me if nobody replies")
    }

    @ViewBuilder
    private func choice(_ title: LocalizedStringKey, _ days: Int?) -> some View {
        if state.remindAfterDays == days { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

import SwiftUI
