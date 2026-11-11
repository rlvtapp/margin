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

    /// Events still to come or happening now, not cancelled or declined: from the account
    /// calendars Margin may read and from invitations in the mail, as the Calendar shows them.
    public var upcomingEvents: [CalendarEntry] {
        let now = Date()
        return agenda(from: now, to: now.addingTimeInterval(60 * 86_400))
            .filter { $0.response != .declined && $0.end > now }
            .sorted { $0.start < $1.start }
            .map(\.asEntry)
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
        await findInvitesInSavedMail()
    }

    /// Invitations anywhere in saved mail from the last two months, not just the inbox: Outlook
    /// moves an invitation to Deleted Items once it's answered, and your answers sit in Sent.
    /// Oldest first, so a meeting is known before replies to it change who's coming.
    func findInvitesInSavedMail(now: Date = Date()) async {
        let words = ["invitation", "invite", "uitnodiging", "invitación", "einladung", "invito", "convite", "@ ",
                     "accepted:", "declined:", "tentative:", "geaccepteerd:", "afgewezen:", "angenommen:", "abgelehnt:",
                     "aceptado:", "rechazado:", "accepté :", "accepté:", "refusé :", "updated invitation", "canceled", "cancelled",
                     "geannuleerd", "abgesagt"]
        let found = await environment.cache.recentMessages(since: now.addingTimeInterval(-60 * 86_400), subjectWords: words)
            .filter { current(contains: $0.account) }
        // Bodies not on the device yet: newest first, so this week's answers come before old mail.
        var fetched = 0
        for (accountID, message) in found.reversed() where message.body == nil && bodies[Self.bodyKey(accountID, message.id)] == nil {
            guard fetched < 30 else { break }
            guard let account = account(accountID), let provider = try? provider(for: account) else { continue }
            if let saved = await environment.cache.body(of: message.id, account: accountID) {
                bodies[Self.bodyKey(accountID, message.id)] = saved
                continue
            }
            fetched += 1
            if let body = try? await provider.body(of: message) {
                bodies[Self.bodyKey(accountID, message.id)] = body
                await environment.cache.saveBody(body, of: message, account: accountID)
            }
        }
        // Then oldest first, so a meeting is known before the replies to it.
        for (accountID, message) in found {
            let key = Self.bodyKey(accountID, message.id)
            if bodies[key] == nil, let body = message.body { bodies[key] = body }
            noteInvites(in: Self.tag(MailThread(id: message.id, messages: [message]), account: accountID))
        }
        noteAnswers(in: found.map(\.message))
    }

    private func current(contains account: UUID) -> Bool { accounts.contains { $0.id == account } }

    /// Your answers from the subjects of replies you sent ("Accepted: Weekly sync"), for replies
    /// whose calendar part isn't on the device. Matched to meetings by title; the newest wins.
    func noteAnswers(in messages: [MailMessage]) {
        let mine = Set(accounts.flatMap { [$0.address] + ($0.aliases ?? []) }.map { $0.address.lowercased() })
        var entries = calendarEntries
        var changed = false
        for message in messages.sorted(by: { $0.date < $1.date }) where mine.contains(message.from.address.lowercased()) {
            guard let (response, title) = Self.answer(inSubject: message.subject) else { continue }
            for index in entries.indices
            where entries[index].title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                rsvps[entries[index].id] = response
                // Kept with the meeting too, as your entry in its guest list.
                let me = message.from.address.lowercased()
                if let at = entries[index].attendees.firstIndex(where: { $0.address.address.lowercased() == me }) {
                    guard entries[index].attendees[at].response != response else { continue }
                    entries[index].attendees[at].response = response
                } else {
                    entries[index].attendees.append(MeetingAttendee(address: message.from, kind: .required, response: response))
                }
                changed = true
            }
        }
        if changed { saveCalendar(entries) }
    }

    /// "Accepted: Weekly sync" → (.accepted, "Weekly sync"), in the languages calendars write.
    static func answer(inSubject subject: String) -> (CalendarInvite.Response, String)? {
        let prefixes: [(String, CalendarInvite.Response)] = [
            ("tentatively accepted:", .tentative), ("tentative:", .tentative), ("accepted:", .accepted), ("declined:", .declined),
            ("voorlopig geaccepteerd:", .tentative), ("voorlopig:", .tentative), ("geaccepteerd:", .accepted), ("afgewezen:", .declined),
            ("mit vorbehalt angenommen:", .tentative), ("angenommen:", .accepted), ("abgelehnt:", .declined),
            ("aceptado provisionalmente:", .tentative), ("provisional:", .tentative), ("aceptado:", .accepted), ("rechazado:", .declined),
            ("accepté provisoirement :", .tentative), ("provisoire :", .tentative), ("accepté :", .accepted), ("refusé :", .declined),
            ("accepté:", .accepted), ("refusé:", .declined), ("accettato:", .accepted), ("rifiutato:", .declined),
            ("aceito:", .accepted), ("recusado:", .declined),
        ]
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for (prefix, response) in prefixes where lower.hasPrefix(prefix) {
            let title = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : (response, title)
        }
        return nil
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
