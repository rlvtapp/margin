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
    /// Seen on its mailbox's calendar: once it's gone from there (declined or removed, maybe in
    /// another app), the invitation no longer brings it back. Never seen there, it stays, since
    /// not every calendar adds invitations before they're answered.
    public var wasOnCalendar: Bool?

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
            noteOwnReply(invite, sentAt: found.message.date)
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
            entry.wasOnCalendar = entries[index].wasOnCalendar
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

    /// Your own answer, sent from any app (an Outlook decline sitting in Sent): it's your answer
    /// now, in place of an older one given in Margin, unless Margin's is newer.
    func noteOwnReply(_ reply: CalendarInvite, sentAt date: Date) {
        let mine = Set(accounts.flatMap(\.sendAddresses).map { $0.address.lowercased() })
        guard let response = reply.attendees.first(where: { mine.contains($0.id) })?.response else { return }
        if let known = sentAnswers[reply.uid], known.at.map({ $0 >= date }) ?? false { return }
        guard sentAnswers[reply.uid]?.response != response || rsvps[reply.uid] != response else { return }
        sentAnswers[reply.uid] = SentAnswer(response: response, sequence: reply.sequence, at: date)
        rsvps[reply.uid] = response
        if !environment.isPreview { saveSentAnswers() }
    }

    /// Keeps the calendar and its reminders up to date.
    func saveCalendar(_ entries: [CalendarEntry]) {
        calendarStore = entries
        if !environment.isPreview { calendarFile.save(entries) }
        scheduleEventReminders()
    }

    /// Loads inbox mail that carries calendar data, so its event is known before
    /// it's opened. Bodies come from the offline cache when they're there.
    public func findInvites() async {
        let recent = Date().addingTimeInterval(-30 * 86_400)
        // Known from the message's structure: it carries a calendar part.
        let candidates = inboxThreads(nil).filter { thread in
            thread.date > recent && thread.messages.contains { $0.calendarMethod != nil }
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
        let found = await environment.cache.recentCalendarMessages(since: now.addingTimeInterval(-60 * 86_400))
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
    }

    private func current(contains account: UUID) -> Bool { accounts.contains { $0.id == account } }

    // MARK: Reminders

    /// Minutes before an event that a reminder comes; 0 turns reminders off.
    public var eventReminderMinutes: Int {
        get { _ = alertRevision; return environment.defaults.object(forKey: "eventReminderMinutes") as? Int ?? 10 }
        set { environment.defaults.set(newValue, forKey: "eventReminderMinutes"); alertRevision += 1; scheduleEventReminders() }
    }

    /// The sound of meeting reminders, apart from new mail's, so a meeting doesn't pass for an email.
    public var reminderSound: AlertSound {
        get { _ = alertRevision; return AlertSound(name: environment.defaults.string(forKey: "reminderSound") ?? "default") }
        set {
            environment.defaults.set(newValue.name, forKey: "reminderSound")
            alertRevision += 1
            playAlertSound(newValue)
            scheduleEventReminders()
        }
    }

    #if canImport(UserNotifications)
    /// What a reminder plays: the system's own sound for Margin's default, a named one, or none.
    static func notificationSound(_ sound: AlertSound) -> UNNotificationSound? {
        switch sound.name {
        case "none": nil
        case "default": .default
        default: UNNotificationSound(named: UNNotificationSoundName(sound.name + ".aiff"))
        }
    }
    #endif

    /// Replaces the pending reminders with one per upcoming event.
    func scheduleEventReminders() {
        #if canImport(UserNotifications)
        guard !environment.isPreview else { return }
        let minutes = eventReminderMinutes
        // Events only in this device's calendars get their alerts from the Calendar app.
        let events = upcomingEvents.filter { !$0.isAllDay && !$0.id.hasPrefix(DeviceCalendar.idPrefix) }.prefix(30)
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
                content.sound = Self.notificationSound(reminderSound)
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
    /// Starts reading the newest conversations ahead, in place of one still going.
    func startReadingAhead() {
        inboxReading?.cancel()
        inboxReading = Task { [weak self] in await self?.readAhead() }
    }

    /// Loads the bodies of the newest conversations in the inbox, from the offline cache when
    /// they're there, so opening them is instant. What isn't saved yet comes in one request
    /// per mailbox and folder, and only the start of each message (its text, not big files;
    /// opening it fetches the rest). It used to be one whole message per request, files and
    /// all, each holding the connection a check needs.
    func readAhead(count: Int = 20) async {
        guard readsAhead else { return }
        let threads = newestInInboxes(count)
        var wanted: [UUID: (provider: any MailProvider, messages: [MailMessage])] = [:]
        for thread in threads {
            guard let account = account(thread.accountID) else { continue }
            for message in thread.messages.suffix(3) {
                guard !Task.isCancelled else { return }
                let key = Self.bodyKey(thread.accountID, message.id)
                guard bodies[key] == nil else { continue }
                if let body = message.body {
                    bodies[key] = body
                } else if let saved = await environment.cache.body(of: message.id, account: account.id) {
                    bodies[key] = saved
                } else if let provider = try? provider(for: account) {
                    wanted[account.id, default: (provider, [])].messages.append(message)
                }
            }
        }
        let cache = environment.cache
        let fetched = await withTaskGroup(of: (UUID, [MailMessage], [String: MessageBody]).self) { group in
            for (accountID, item) in wanted {
                group.addTask { (accountID, item.messages, (try? await item.provider.readableBodies(of: item.messages)) ?? [:]) }
            }
            var all: [(UUID, [MailMessage], [String: MessageBody])] = []
            for await answer in group { all.append(answer) }
            return all
        }
        for (accountID, messages, found) in fetched {
            for message in messages {
                guard let body = found[message.id] else { continue }
                let key = Self.bodyKey(accountID, message.id)
                // The open conversation may have fetched the whole message meanwhile; a start
                // isn't put back over it, here or in saved mail.
                guard bodies[key] == nil || bodies[key]?.isPartial == true else { continue }
                bodies[key] = body
                await cache.saveBody(body, of: message, account: accountID)
            }
        }
        for thread in threads { forgetNote(of: thread.id) }
    }

    /// Fetches a conversation's latest messages before they're asked for, on the background
    /// connection, and saves them, so opening it shows the text at once.
    func readAhead(_ thread: MailThread) async {
        guard let account = account(thread.accountID) else { return }
        for message in thread.messages.suffix(3) {
            guard !Task.isCancelled else { return }
            let key = Self.bodyKey(thread.accountID, message.id)
            guard bodies[key] == nil else { continue }
            if let body = message.body {
                bodies[key] = body
            } else if let saved = await environment.cache.body(of: message.id, account: account.id) {
                bodies[key] = saved
            } else if let provider = try? provider(for: account), let body = try? await provider.body(of: message) {
                // The open conversation may have fetched it meanwhile; a start isn't put back
                // over the whole message.
                if bodies[key] == nil || bodies[key]?.isPartial == true { bodies[key] = body }
                await environment.cache.saveBody(body, of: message, account: account.id)
            }
        }
    }

    /// While one conversation is being read, the ones you're most likely to open next are
    /// fetched: the two below it in the list and the one above. Choosing another conversation
    /// starts this over from there.
    func readAhead(around thread: MailThread) {
        neighbourReading?.cancel()
        guard readsAhead else { return }
        let threads = listSections(visibleThreads)?.flatMap(\.threads) ?? visibleThreads
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        let next = [index + 1, index + 2, index - 1].filter(threads.indices.contains).map { threads[$0] }
        neighbourReading = Task { [weak self] in
            for neighbour in next {
                guard !Task.isCancelled else { return }
                await self?.readAhead(neighbour)
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
