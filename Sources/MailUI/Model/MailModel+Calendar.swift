import Foundation
import MailCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// One event Margin knows about from an invitation in the mail.
public struct CalendarEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var joinURL: URL?
    public var organizer: String?
    public var threadID: String
    public var cancelled: Bool
    /// Who's invited and how they answered, kept up to date from replies and the account's calendar.
    public var attendees: [MeetingAttendee] = []
    /// The account the meeting belongs to.
    public var accountID: UUID?
    /// Sent from here, so answers come back to this person.
    public var isMine = false

    public var finish: Date { end ?? start.addingTimeInterval(isAllDay ? 86_400 : 3600) }
}

/// A calendar built from invitations in the mail: the next meeting at the top of the list,
/// with Join, and a reminder before each one.
extension MailModel {
    private var calendarFile: JSONFile<[CalendarEntry]> { JSONFile(url: environment.folder.appending(path: "calendar.json")) }

    /// Every event from an invitation, soonest first.
    public var calendarEntries: [CalendarEntry] {
        if let calendarStore { return calendarStore }
        let loaded = environment.isPreview ? [] : (calendarFile.load() ?? [])
        calendarStore = loaded
        return loaded
    }

    /// Events still to come or happening now, not cancelled or declined.
    public var upcomingEvents: [CalendarEntry] {
        let now = Date()
        return calendarEntries.filter { !$0.cancelled && $0.finish > now && rsvps[$0.id] != .declined }.sorted { $0.start < $1.start }
    }

    /// The event to show at the top: one happening now, or starting in the next few hours.
    public var nextEvent: CalendarEntry? {
        _ = clockTick
        let soon = Date().addingTimeInterval(4 * 3600)
        return upcomingEvents.first { !$0.isAllDay && $0.start < soon }
    }

    /// Today's events, for Home.
    public var todaysEvents: [CalendarEntry] {
        upcomingEvents.filter { Calendar.current.isDateInToday($0.start) }
    }

    /// Remembers the invitations in a conversation whose bodies have loaded.
    func noteInvites(in thread: MailThread) {
        guard let found = invite(in: thread) else { return }
        let invite = found.invite
        var entries = calendarEntries
        // A reply: someone answered a meeting; it changes their answer, not the meeting.
        if invite.method == "REPLY" {
            guard let index = entries.firstIndex(where: { $0.id == invite.uid }) else { return }
            let updated = entries[index].attendees.updating(with: invite.attendees)
            guard updated != entries[index].attendees else { return }
            entries[index].attendees = updated
            saveCalendar(entries)
            return
        }
        guard let start = invite.start else { return }
        let mine = Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() })
        var entry = CalendarEntry(id: invite.uid, title: invite.summary, start: start, end: invite.end, isAllDay: invite.isAllDay,
                                  location: invite.location, joinURL: invite.joinURL, organizer: invite.organizer?.displayName,
                                  threadID: thread.id, cancelled: invite.isCancelled)
        entry.accountID = thread.accountID
        entry.isMine = invite.organizer.map { mine.contains($0.address.lowercased()) } ?? false
        entry.attendees = invite.attendees
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            // Answers already known stay; the invitation's own list may be older.
            entry.attendees = invite.attendees.updating(with: entries[index].attendees.filter { $0.response != nil })
            guard entries[index] != entry else { return }
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        // Keep what's useful: the next months and the last week.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        entries.removeAll { $0.finish < cutoff }
        calendarStore = entries
        if !environment.isPreview { calendarFile.save(entries) }
        scheduleEventReminders()
    }

    /// Keeps the calendar and its reminders up to date.
    func saveCalendar(_ entries: [CalendarEntry]) {
        calendarStore = entries
        if !environment.isPreview { calendarFile.save(entries) }
        scheduleEventReminders()
    }

    /// Loads mail in the inbox that looks like an invitation, so its event is known before
    /// it's opened. Bodies come from the offline cache when they're there.
    public func findInvites() async {
        let words = ["invitation", "invite", "uitnodiging", "invitación", "einladung", "invito", "convite", "meeting", "@ "]
        let recent = Date().addingTimeInterval(-30 * 86_400)
        let candidates = inboxThreads(nil).filter { thread in
            thread.date > recent && words.contains { thread.subject.lowercased().contains($0) }
        }
        for thread in candidates.prefix(40) {
            guard let account = account(thread.accountID), let provider = try? provider(for: account) else { continue }
            for message in thread.messages {
                let key = Self.bodyKey(thread.accountID, message.id)
                guard bodies[key] == nil else { continue }
                if let body = message.body {
                    bodies[key] = body
                } else if let saved = await environment.cache.body(of: message.id, account: account.id) {
                    bodies[key] = saved
                } else if let body = try? await provider.body(of: message) {
                    bodies[key] = body
                    await environment.cache.saveBody(body, of: message, account: account.id)
                }
            }
            noteInvites(in: thread)
        }
    }

    // MARK: Reminders

    /// Minutes before an event that a reminder comes; 0 turns reminders off.
    public var eventReminderMinutes: Int {
        get { _ = alertRevision; return environment.defaults.object(forKey: "eventReminderMinutes") as? Int ?? 10 }
        set { environment.defaults.set(newValue, forKey: "eventReminderMinutes"); alertRevision += 1; scheduleEventReminders() }
    }

    /// Replaces the pending reminders with one per upcoming event.
    func scheduleEventReminders() {
        #if canImport(UserNotifications)
        guard !environment.isPreview else { return }
        let minutes = eventReminderMinutes
        let events = upcomingEvents.filter { !$0.isAllDay }.prefix(30)
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("event-") }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard minutes > 0 else { return }
            for event in events {
                let when = event.start.addingTimeInterval(-Double(minutes) * 60)
                guard when > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = event.title
                content.body = String(localized: "Starts at \(event.start.formatted(date: .omitted, time: .shortened))")
                    + (event.location.map { " · " + $0 } ?? "")
                content.userInfo = ["threadID": event.threadID]
                content.interruptionLevel = .timeSensitive
                content.sound = .default
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
                let request = UNNotificationRequest(identifier: "event-\(event.id)", content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                try? await center.add(request)
            }
        }
        #endif
    }
}

extension MailModel {
    /// Loads the bodies of the newest conversations in the inbox, from the offline cache when
    /// they're there, so opening them is instant.
    func readAhead(count: Int = 12) async {
        guard !environment.isPreview else { return }
        for thread in inboxThreads(nil).prefix(count) {
            guard let account = account(thread.accountID) else { continue }
            for message in thread.messages.suffix(3) {
                let key = Self.bodyKey(thread.accountID, message.id)
                guard bodies[key] == nil else { continue }
                if let body = message.body {
                    bodies[key] = body
                } else if let saved = await environment.cache.body(of: message.id, account: account.id) {
                    bodies[key] = saved
                } else if let provider = try? provider(for: account), let body = try? await provider.body(of: message) {
                    bodies[key] = body
                    await environment.cache.saveBody(body, of: message, account: account.id)
                }
            }
        }
    }
}

extension MailModel {
    /// Sample mode only: a meeting about to start, so screenshots show the next-meeting chip.
    public func addSampleMeeting() {
        guard environment.isPreview else { return }
        let start = Date().addingTimeInterval(6 * 60)
        calendarStore = calendarEntries + [CalendarEntry(id: "sample-design-review", title: "Design review", start: start,
                                                         end: start.addingTimeInterval(1800), isAllDay: false, location: nil,
                                                         joinURL: URL(string: "https://meet.example.com/design"), organizer: "Lena Fischer",
                                                         threadID: inboxThreads(nil).first?.id ?? "", cancelled: false)]
    }
}
