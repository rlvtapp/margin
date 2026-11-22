import Foundation
import MailCore
import os

/// One row in the Calendar view: an event from an account's calendar, an invitation found in
/// the mail, or both when they're the same meeting.
public struct AgendaItem: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// In an account's calendar; answered through its API.
        case account(UUID, eventID: String)
        /// Only known from an invitation email; answered with a reply email.
        case invite(threadID: String, accountID: UUID?)
        /// In this device's Calendar app, through EventKit.
        case device(eventID: String)
    }

    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var joinURL: URL?
    public var organizer: String?
    public var response: CalendarInvite.Response?
    /// You organized it, so there's nothing to answer.
    public var isMine: Bool
    public var repeats: Bool
    public var source: Source
    /// The conversation the invitation came in, when Margin has it.
    public var invitationThreadID: String?
    /// Everyone invited, with their answers when known.
    public var attendees: [MeetingAttendee] = []
    /// The iCalendar UID when known, to match the invitation email.
    public var uid: String?
    /// The calendar it's in, for events from this device.
    public var calendarName: String?
    /// The notes when the calendar gives them in full.
    public var notes: String?
    /// Whether it can be changed or deleted from here (`MailModel+EventEditing`).
    public var canChange = false
    /// Its colour, as an index into the account colours: the mailbox's, or the device
    /// calendar's own colour brought to the nearest one.
    public var colorIndex = 0
    /// Which of a mailbox's calendars it's in, when the mailbox has several.
    public var calendarID: String?

    /// Which entry in the Calendar's list it belongs to, for hiding it.
    public var calendarKey: String {
        switch source {
        case .account(let id, _): calendarID.map { MailModel.calendarKey(account: id, calendar: $0) } ?? MailModel.calendarKey(account: id)
        case .invite(_, let id): id.map(MailModel.calendarKey(account:)) ?? "invitations"
        case .device: MailModel.calendarKey(device: calendarName ?? "")
        }
    }

    /// Whether Going? can be answered from here: you were invited, and it came from mail or an
    /// account's calendar (the device's calendars can only be read).
    public var canAnswer: Bool {
        if isMine { return false }
        if case .device = source { return false }
        return true
    }

    /// Whether it came from this device's Calendar app.
    public var isFromDevice: Bool {
        if case .device = source { return true }
        return false
    }

    /// The source's own id for the event.
    public var eventID: String {
        switch source {
        case .account(_, let id), .device(let id): id
        case .invite: id
        }
    }

    /// The same meeting as a calendar entry, for the parts of the app that show one.
    var asEntry: CalendarEntry {
        var entry = CalendarEntry(id: id, title: title, start: start, end: end, isAllDay: isAllDay, location: location,
                                  joinURL: joinURL, organizer: organizer, threadID: invitationThreadID ?? "", cancelled: false)
        entry.attendees = attendees
        entry.accountID = accountID
        entry.isMine = isMine
        return entry
    }

    public var accountID: UUID? {
        switch source {
        case .account(let id, _): id
        case .invite(_, let id): id
        case .device: nil
        }
    }
}

extension MailModel {
    /// Counts and errors only, never what's in a calendar.
    static let calendarLog = Logger(subsystem: "app.relevate.margin", category: "calendar")

    nonisolated static func calendarKey(account: UUID) -> String { "account:\(account.uuidString)" }
    nonisolated static func calendarKey(account: UUID, calendar: String) -> String { "account:\(account.uuidString):\(calendar)" }
    nonisolated static func calendarKey(device name: String) -> String { "device:\(name)" }
    nonisolated static let remindersKey = "reminders"

    /// Whether a calendar in the list is ticked.
    public func isCalendarShown(_ key: String) -> Bool { !hiddenCalendars.contains(key) }

    public func setCalendarShown(_ key: String, _ shown: Bool) {
        if shown { hiddenCalendars.remove(key) } else { hiddenCalendars.insert(key) }
        environment.defaults.set(Array(hiddenCalendars).sorted(), forKey: "calendar.hidden")
    }

    /// Drops what was read from an account's calendar (after it's disconnected).
    public func forgetCalendar(of account: UUID) {
        calendarEvents[account] = nil
        calendarEventsRange = nil
    }

    /// Whether any account lets Margin read its calendar.
    public var readsAccountCalendars: Bool {
        accounts.contains { usesAccountCalendar($0) }
    }

    /// Everything on the calendar between two moments, soonest first: account calendars, and
    /// invitations from mail that aren't already there. Cancelled events are left out.
    public func agenda(from start: Date, to end: Date) -> [AgendaItem] {
        agenda(from: start, to: end, accountEvents: calendarEvents, deviceEvents: deviceEvents, accountsRead: calendarEventsRange)
    }

    /// The same, from events read for another range (AI apps asking about other months), so the
    /// page's own months stay as they are. `accountsRead` is the time `accountEvents` covers.
    func agenda(from start: Date, to end: Date, accountEvents: [UUID: [CalendarEvent]], deviceEvents: [CalendarEvent],
                accountsRead: ClosedRange<Date>? = nil) -> [AgendaItem] {
        var items: [AgendaItem] = []
        var seen = Set<String>()
        // An invitation in the mail and the same meeting in a calendar are one item. They're
        // matched by UID (as calendars write it, see `meetingUID`), else by title and start.
        let invitations = Dictionary(calendarEntries.map { (Self.meetingUID($0.id), $0.threadID) }, uniquingKeysWith: { first, _ in first })
        let invitationsByTime = Dictionary(calendarEntries.map { (Self.sameMeetingKey($0.title, $0.start), $0.threadID) },
                                           uniquingKeysWith: { first, _ in first })
        var shownAt = Set<String>()
        func invitation(uid: String?, title: String, start: Date) -> String? {
            uid.flatMap { invitations[Self.meetingUID($0)] } ?? invitationsByTime[Self.sameMeetingKey(title, start)]
        }
        for account in accounts {
            for event in accountEvents[account.id] ?? [] where !event.isCancelled && event.end > start && event.start < end {
                let key = Self.meetingUID(event.uid ?? event.id) + "|\(event.start.timeIntervalSince1970)"
                guard seen.insert(key).inserted else { continue }
                seen.insert(Self.meetingUID(event.uid ?? event.id))
                shownAt.insert(Self.sameMeetingKey(event.title, event.start))
                items.append(AgendaItem(
                    id: "\(account.id)|\(event.id)", title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                    location: event.location, joinURL: event.joinURL, organizer: event.organizer,
                    response: answering[event.uid ?? event.id] ?? rsvps[event.uid ?? event.id] ?? event.response, isMine: event.isOrganizer, repeats: event.repeats,
                    source: .account(account.id, eventID: event.id),
                    invitationThreadID: invitation(uid: event.uid, title: event.title, start: event.start), attendees: event.attendees,
                    uid: event.uid, calendarName: event.calendarName, notes: event.notes, canChange: event.canChange,
                    colorIndex: colorIndex(of: event, in: account), calendarID: event.calendarID))
            }
        }
        let current = Set(accounts.map(\.id))
        let mine = Set(accounts.flatMap { [$0.address] + ($0.aliases ?? []) }.map { $0.address.lowercased() })
        for entry in calendarEntries where !entry.cancelled && entry.finish > start && entry.start < end {
            guard !seen.contains(Self.meetingUID(entry.id)), !shownAt.contains(Self.sameMeetingKey(entry.title, entry.start)),
                  entry.accountID.map(current.contains) ?? true else { continue }
            // It was on its mailbox's calendar, which has been read for that day, and it's gone:
            // declined or removed there (in another app too), so the old invitation doesn't
            // bring it back.
            if entry.wasOnCalendar == true, let account = entry.accountID, accountEvents[account] != nil,
               accountsRead?.contains(entry.start) == true { continue }
            items.append(AgendaItem(
                id: entry.id, title: entry.title, start: entry.start, end: entry.finish, isAllDay: entry.isAllDay,
                location: entry.location, joinURL: entry.joinURL, organizer: entry.organizer,
                response: answering[entry.id] ?? rsvps[entry.id] ?? entry.attendees.first { mine.contains($0.address.address.lowercased()) }?.response,
                isMine: entry.isMine, repeats: false, source: .invite(threadID: entry.threadID, accountID: entry.accountID),
                invitationThreadID: entry.threadID, attendees: entry.attendees, uid: entry.id,
                colorIndex: entry.accountID.flatMap { self.account($0)?.colorIndex } ?? 0))
            seen.insert(Self.meetingUID(entry.id))
        }
        // This device's calendars last: a meeting already shown from the mail or an account
        // (the same UID, or the same title at the same time) isn't shown twice.
        if showsDeviceCalendar {
            var shown = Set(items.map { Self.sameMeetingKey($0.title, $0.start) })
            for event in deviceEvents where !event.isCancelled && event.end > start && event.start < end {
                if let uid = event.uid, seen.contains(Self.meetingUID(uid)) { continue }
                guard shown.insert(Self.sameMeetingKey(event.title, event.start)).inserted else { continue }
                items.append(AgendaItem(
                    id: event.id, title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                    location: event.location, joinURL: event.joinURL, organizer: event.isOrganizer ? nil : event.organizer,
                    response: event.response, isMine: event.isOrganizer, repeats: event.repeats,
                    source: .device(eventID: event.id), invitationThreadID: invitation(uid: event.uid, title: event.title, start: event.start),
                    attendees: event.attendees, uid: event.uid, calendarName: event.calendarName,
                    notes: event.notes, canChange: event.canChange, colorIndex: event.calendarColor.map(Palette.nearestAccountIndex(to:)) ?? 0))
            }
        }
        // Hiding a mailbox hides all its calendars; each can also be hidden on its own.
        items = items.filter { item in
            if hiddenCalendars.contains(item.calendarKey) { return false }
            if case .account(let id, _) = item.source, hiddenCalendars.contains(Self.calendarKey(account: id)) { return false }
            return true
        }
        return items.sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
            .sorted { Calendar.current.startOfDay(for: $0.start) < Calendar.current.startOfDay(for: $1.start) }
    }

    /// A meeting's UID the same way however it arrived. Microsoft calendars give a meeting
    /// from elsewhere an id of their own (hex, starting `040000008200E00074C5B7101A82E008`)
    /// that carries the invitation's UID after a `vCal-Uid` marker, and give each occurrence of
    /// a repeating meeting its own id by putting the day in bytes 16–19. Both are undone here.
    static func meetingUID(_ uid: String) -> String {
        let lower = uid.lowercased()
        let prefix = "040000008200e00074c5b7101a82e008"
        guard lower.hasPrefix(prefix), lower.count >= 40, lower.count % 2 == 0, let bytes = hexBytes(lower) else { return lower }
        let marker = Array("vCal-Uid".utf8)
        if let at = bytes.firstRange(of: marker) {
            // The marker, then a 4-byte version, then the UID, ending in a zero byte.
            let text = bytes[min(bytes.count, at.upperBound + 4)...].prefix { $0 != 0 }
            if let uid = String(bytes: text, encoding: .utf8), !uid.isEmpty { return uid.lowercased() }
        }
        var series = bytes
        for index in 16..<20 { series[index] = 0 }
        return series.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// The mailbox's colour for its main calendar; another calendar's own colour when it has one.
    func colorIndex(of event: CalendarEvent, in account: MailAccount) -> Int {
        guard let id = event.calendarID, let color = event.calendarColor,
              accountCalendars[account.id]?.first(where: { $0.id == id })?.isDefault != true else { return account.colorIndex }
        return Palette.nearestAccountIndex(to: color)
    }

    static let defaultHourHeight: Double = 48

    /// What else is on at the same time as a meeting (an invitation in the mail): timed events
    /// you haven't declined, leaving out the meeting itself.
    public func clashes(start: Date, end: Date, uid: String?, title: String) -> [AgendaItem] {
        guard end > start else { return [] }
        let same = uid.map(Self.meetingUID)
        let key = Self.sameMeetingKey(title, start)
        return agenda(from: start, to: end).filter { item in
            !item.isAllDay && item.response != .declined && item.start < end && item.end > start
                && (same == nil || Self.meetingUID(item.uid ?? item.id) != same)
                && Self.sameMeetingKey(item.title, item.start) != key
        }
    }

    /// Taller (1) or shorter (−1) hours in Day and Week, in steps; 0 goes back to the usual size.
    public func zoomCalendar(_ step: Int) {
        calendarHourHeight = step == 0 ? max(Self.defaultHourHeight, smallestHourHeight)
            : min(max(calendarHourHeight + Double(step) * 8, smallestHourHeight), 120)
    }

    /// Whether ⌘+ and ⌘− zoom the hours instead of the text: Day or Week is on screen.
    public var zoomsCalendar: Bool {
        place == .calendar && ["day", "week"].contains(UserDefaults.standard.string(forKey: "calendarMode") ?? "")
    }

    static func sameMeetingKey(_ title: String, _ start: Date) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|\(Int(start.timeIntervalSince1970))"
    }

    /// The days in a range with something on them, for the dots in the month.
    /// What the Calendar page draws: the agenda without meetings you declined, which leave your
    /// calendar as they do in other calendar apps. Their invitation still has the answer, to
    /// change it later.
    public func calendarItems(from start: Date, to end: Date) -> [AgendaItem] {
        agenda(from: start, to: end).filter { $0.response != .declined }
    }

    public func daysWithEvents(from start: Date, to end: Date) -> Set<Date> {
        let calendar = Calendar.current
        var days = Set<Date>()
        for item in calendarItems(from: start, to: end) {
            var day = calendar.startOfDay(for: max(item.start, start))
            let last = item.isAllDay ? item.end.addingTimeInterval(-1) : item.end
            while day <= last && day < end {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        for reminder in dueReminders where isCalendarShown(Self.remindersKey) && !reminder.isDone && reminder.due >= start && reminder.due < end {
            days.insert(calendar.startOfDay(for: reminder.due))
        }
        return days
    }

    /// Reads the account calendars around a day: its month, a week either side. Kept until
    /// another month is shown or Refresh is pressed.
    public func refreshCalendar(around day: Date = Date(), force: Bool = false) async {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: day) ?? DateInterval(start: day, duration: 31 * 86_400)
        let start = calendar.date(byAdding: .day, value: -7, to: month.start) ?? month.start
        let end = calendar.date(byAdding: .day, value: 14, to: month.end) ?? month.end
        await refreshDeviceCalendar(around: day, force: force)
        await refreshColleagues(around: day, force: force)
        if !force, let range = calendarEventsRange, range.contains(start), range.contains(end) { return }
        var readers: [(UUID, any CalendarReading)] = []
        for account in accounts where usesAccountCalendar(account) {
            do {
                if let reader = try await calendarAdapter(for: account) as? any CalendarReading {
                    readers.append((account.id, reader))
                } else {
                    Self.calendarLog.error("calendar \(account.id.uuidString.prefix(8), privacy: .public): no reader for this provider")
                }
            } catch {
                Self.calendarLog.error("calendar \(account.id.uuidString.prefix(8), privacy: .public): sign-in failed: \(error.localizedDescription, privacy: .public)")
                if force { show(error, account: account.id) }
            }
        }
        Self.calendarLog.info("calendar refresh: \(readers.count, privacy: .public) of \(self.accounts.count, privacy: .public) mailboxes connected")
        guard !readers.isEmpty else { return }
        let results = await withTaskGroup(of: (UUID, Result<([AccountCalendar]?, [CalendarEvent]), Error>).self) { group in
            for (id, reader) in readers {
                group.addTask {
                    do { return (id, .success(try await Self.readAll(reader, from: start, to: end))) } catch { return (id, .failure(error)) }
                }
            }
            var all: [(UUID, Result<([AccountCalendar]?, [CalendarEvent]), Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (id, result) in results {
            switch result {
            case .success(let (calendars, events)):
                if let calendars { accountCalendars[id] = calendars }
                calendarEvents[id] = events
                Self.calendarLog.info("calendar \(id.uuidString.prefix(8), privacy: .public): \(events.count, privacy: .public) events")
            case .failure(let error):
                Self.calendarLog.error("calendar \(id.uuidString.prefix(8), privacy: .public): reading failed: \(String(describing: error), privacy: .public)")
                if force { show(error, account: id) }
            }
        }
        calendarEventsRange = start...end
        noteInvitationsOnCalendars()
        // What the calendars say now decides the reminders (a meeting declined elsewhere goes).
        scheduleEventReminders()
    }

    /// Marks the invitations now on their mailbox's calendar (`CalendarEntry.wasOnCalendar`).
    func noteInvitationsOnCalendars() {
        var onCalendar = Set<String>()
        for events in calendarEvents.values {
            for event in events {
                onCalendar.insert(Self.meetingUID(event.uid ?? event.id))
                onCalendar.insert(Self.sameMeetingKey(event.title, event.start))
            }
        }
        var entries = calendarEntries
        var changed = false
        for index in entries.indices where entries[index].wasOnCalendar != true {
            let entry = entries[index]
            guard onCalendar.contains(Self.meetingUID(entry.id)) || onCalendar.contains(Self.sameMeetingKey(entry.title, entry.start)) else { continue }
            entries[index].wasOnCalendar = true
            changed = true
        }
        if changed { saveCalendar(entries) }
    }

    /// Every calendar of a mailbox, each event marked with its calendar. A calendar that can't be
    /// read (a shared one taken back) is left out rather than failing the rest. Without a list,
    /// just the main calendar.
    nonisolated static func readAll(_ reader: any CalendarReading, from start: Date, to end: Date) async throws -> ([AccountCalendar]?, [CalendarEvent]) {
        guard let listing = reader as? any CalendarListing, let calendars = try? await listing.calendars(), !calendars.isEmpty else {
            return (nil, try await reader.events(from: start, to: end))
        }
        let events = await withTaskGroup(of: [CalendarEvent].self) { group in
            for calendar in calendars {
                group.addTask { (try? await listing.events(in: calendar, from: start, to: end)) ?? [] }
            }
            var all: [CalendarEvent] = []
            for await found in group { all += found }
            return all
        }
        return (calendars, events)
    }

    /// Answers an event: through the account's calendar when it came from there, otherwise
    /// with a reply to the invitation email. One answer at a time per event: taps while one is
    /// on its way do nothing.
    @discardableResult
    public func respond(to item: AgendaItem, with response: CalendarInvite.Response) -> Task<Void, Never>? {
        let key = eventKey(item)
        guard answering[key] == nil else { return nil }
        switch item.source {
        case .account(let accountID, let eventID):
            guard let account = account(accountID) else {
                notice = Notice(text: String(localized: "Couldn't answer “\(item.title)”: its account isn't in Margin anymore.", table: "Calendar"), isError: true)
                return nil
            }
            let previous = rsvps[key]
            answering[key] = response
            rsvps[key] = response
            return Task {
                defer { answering[key] = nil }
                do {
                    guard let reader = try await calendarAdapter(for: account) as? any CalendarReading else {
                        rsvps[key] = previous
                        notice = Notice(text: String(localized: "Couldn't answer “\(item.title)”: the account's calendar can't be reached.", table: "Calendar"), isError: true)
                        return
                    }
                    try await reader.respond(toEvent: eventID, with: response)
                    if var events = calendarEvents[accountID], let index = events.firstIndex(where: { $0.id == eventID }) {
                        events[index].response = response
                        calendarEvents[accountID] = events
                    }
                    notice = Notice(text: String(localized: "Replied \(response.shortTitle) to “\(item.title)”", table: "Calendar"), isSent: true)
                } catch {
                    rsvps[key] = previous
                    show(error)
                }
            }
        case .device:
            return nil
        case .invite(let threadID, _):
            // Marked before the invitation is looked up, so a second tap meanwhile is ignored.
            answering[key] = response
            return Task {
                guard let thread = await invitationThread(threadID) else {
                    answering[key] = nil
                    notice = Notice(text: String(localized: "The invitation for “\(item.title)” isn't in your inbox anymore.", table: "Calendar"))
                    return
                }
                let found = await askContext([thread]).first?.1 ?? [:]
                guard let invite = thread.messages.reversed().compactMap({ found[$0.id]?.invite }).first(where: { $0.method != "REPLY" }) else {
                    answering[key] = nil
                    notice = Notice(text: String(localized: "The invitation for “\(item.title)” couldn't be read.", table: "Calendar"))
                    return
                }
                // The reader card may be sending an answer to this invitation already.
                if invite.uid != key, answering[invite.uid] != nil {
                    answering[key] = nil
                    return
                }
                answering[invite.uid] = response
                await sendAnswer(to: invite, in: thread, with: response, key: key)?.value
            }
        }
    }

    /// Whether an answer to this event is still on its way.
    public func isAnswering(_ item: AgendaItem) -> Bool { answering[eventKey(item)] != nil }

    /// A sample week in the first account's calendar, for screenshots and previews.
    public func addSampleCalendar() {
        guard environment.isPreview, let account = accounts.first else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: (day * 24 + hour) * 60 + minute, to: today) ?? today
        }
        let link = URL(string: "https://meet.example.com/room")
        let now = Date()
        func soon(_ minutes: Int) -> Date {
            let rounded = (now.addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970 / 300).rounded() * 300
            return Date(timeIntervalSince1970: rounded)
        }
        func people(_ names: [String]) -> [MeetingAttendee] {
            names.map { MeetingAttendee(address: EmailAddress(name: $0, address: $0.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com")) }
        }
        var review = CalendarEvent(id: "s2", title: "Roadmap review", start: soon(-50), end: soon(-10), joinURL: link,
                                   organizer: "Ava Martin", response: .accepted)
        review.attendees = people(["Ava Martin", "Leo Brooks"])
        var critique = CalendarEvent(id: "s3", title: "Design critique", start: soon(25), end: soon(70), joinURL: link,
                                     organizer: "Noor Haddad", response: .tentative)
        critique.attendees = people(["Noor Haddad", "Sam Ortiz", "Maya Chen", "Leo Brooks", "Ava Martin", "Lena Fischer"])
        var standup = CalendarEvent(id: "s4", title: "Standup", start: soon(120), end: soon(135), joinURL: link,
                                    organizer: "Leo Brooks", response: .accepted, repeats: true)
        standup.attendees = people(["Leo Brooks", "Sam Ortiz"])
        calendarEvents[account.id] = [
            CalendarEvent(id: "s1", title: "Release freeze", start: today, end: at(1, 0), isAllDay: true, organizer: "Ava Martin"),
            review, critique, standup,
            CalendarEvent(id: "s5", title: "Vendor demo", start: soon(125), end: soon(155), joinURL: link,
                          organizer: "Marcus Chen"),
            CalendarEvent(id: "s6", title: "Weekly sync", start: at(1, 10), end: at(1, 10, 30), location: "Room 4, floor 2",
                          organizer: "Leo Brooks", response: .accepted, repeats: true),
            CalendarEvent(id: "s7", title: "Quarterly planning with finance and the leadership team", start: at(1, 14), end: at(1, 15),
                          location: "Room 4, floor 2", organizer: "Maya Chen"),
            CalendarEvent(id: "s8", title: "1:1 with Sam", start: at(3, 9, 30), end: at(3, 10), isOrganizer: true),
        ]
        calendarEventsRange = at(-40, 0)...at(60, 0)
        addSampleDeviceCalendar(today: today)
        addSampleColleagues(today: today)
    }

    /// Opens the email an invitation came in, wherever it is now, titled with the meeting.
    public func showInvitation(threadID: String, title: String? = nil) {
        Task {
            guard let thread = await invitationThread(threadID) else {
                notice = Notice(text: String(localized: "The invitation for “\(title ?? "")” isn't in your inbox anymore.", table: "Calendar"))
                return
            }
            place = .search(title ?? thread.subject)
            folder = [thread]
            selectedThreadID = thread.id
            isReaderOpen = true
            await loadBodies()
        }
    }

    /// The conversation an invitation came in: in an inbox, the folder shown, or saved mail
    /// (Deleted Items, where Outlook puts answered invitations).
    func invitationThread(_ threadID: String) async -> MailThread? {
        if let thread = allInboxesThreads(nil).first(where: { $0.id == threadID }) ?? folder.first(where: { $0.id == threadID }) {
            return thread
        }
        let parts = threadID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let account = UUID(uuidString: parts[0]),
              let message = await environment.cache.message(id: parts[1], account: account) else { return nil }
        return Self.tag(MailThread(id: message.id, messages: [message]), account: account)
    }

    private func eventKey(_ item: AgendaItem) -> String {
        if case .account(let accountID, let eventID) = item.source,
           let event = calendarEvents[accountID]?.first(where: { $0.id == eventID }) {
            return event.uid ?? event.id
        }
        return item.id
    }
}

extension CalendarInvite.Response {
    /// "Yes", "Maybe", "No": the answers as the Calendar's buttons say them.
    public var shortTitle: String {
        switch self {
        case .accepted: String(localized: "Yes", table: "Calendar", comment: "Going to a meeting")
        case .tentative: String(localized: "Maybe", table: "Calendar", comment: "Going to a meeting")
        case .declined: String(localized: "No", table: "Calendar", comment: "Going to a meeting")
        }
    }
}
