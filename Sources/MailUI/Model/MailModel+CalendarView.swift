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
        }
    }
}

extension MailModel {
    /// Counts and errors only, never what's in a calendar.
    static let calendarLog = Logger(subsystem: "app.relevate.margin", category: "calendar")

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
        var items: [AgendaItem] = []
        var seen = Set<String>()
        let invitations = Dictionary(calendarEntries.map { ($0.id.lowercased(), $0.threadID) }, uniquingKeysWith: { first, _ in first })
        for account in accounts {
            for event in calendarEvents[account.id] ?? [] where !event.isCancelled && event.end > start && event.start < end {
                let key = (event.uid ?? event.id).lowercased() + "|\(event.start.timeIntervalSince1970)"
                guard seen.insert(key).inserted else { continue }
                seen.insert((event.uid ?? event.id).lowercased())
                items.append(AgendaItem(
                    id: "\(account.id)|\(event.id)", title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay,
                    location: event.location, joinURL: event.joinURL, organizer: event.organizer,
                    response: rsvps[event.uid ?? event.id] ?? event.response, isMine: event.isOrganizer, repeats: event.repeats,
                    source: .account(account.id, eventID: event.id),
                    invitationThreadID: event.uid.flatMap { invitations[$0.lowercased()] }, attendees: event.attendees))
            }
        }
        let current = Set(accounts.map(\.id))
        let mine = Set(accounts.flatMap { [$0.address] + ($0.aliases ?? []) }.map { $0.address.lowercased() })
        for entry in calendarEntries where !entry.cancelled && entry.finish > start && entry.start < end {
            guard !seen.contains(entry.id.lowercased()), entry.accountID.map(current.contains) ?? true else { continue }
            items.append(AgendaItem(
                id: entry.id, title: entry.title, start: entry.start, end: entry.finish, isAllDay: entry.isAllDay,
                location: entry.location, joinURL: entry.joinURL, organizer: entry.organizer,
                response: rsvps[entry.id] ?? entry.attendees.first { mine.contains($0.address.address.lowercased()) }?.response,
                isMine: entry.isMine, repeats: false, source: .invite(threadID: entry.threadID, accountID: entry.accountID),
                invitationThreadID: entry.threadID, attendees: entry.attendees))
        }
        return items.sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
            .sorted { Calendar.current.startOfDay(for: $0.start) < Calendar.current.startOfDay(for: $1.start) }
    }

    /// The days in a range with something on them, for the dots in the month.
    public func daysWithEvents(from start: Date, to end: Date) -> Set<Date> {
        let calendar = Calendar.current
        var days = Set<Date>()
        for item in agenda(from: start, to: end) {
            var day = calendar.startOfDay(for: max(item.start, start))
            let last = item.isAllDay ? item.end.addingTimeInterval(-1) : item.end
            while day <= last && day < end {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
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
                if force { show(error) }
            }
        }
        Self.calendarLog.info("calendar refresh: \(readers.count, privacy: .public) of \(self.accounts.count, privacy: .public) mailboxes connected")
        guard !readers.isEmpty else { return }
        let results = await withTaskGroup(of: (UUID, Result<[CalendarEvent], Error>).self) { group in
            for (id, reader) in readers {
                group.addTask {
                    do { return (id, .success(try await reader.events(from: start, to: end))) } catch { return (id, .failure(error)) }
                }
            }
            var all: [(UUID, Result<[CalendarEvent], Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (id, result) in results {
            switch result {
            case .success(let events):
                calendarEvents[id] = events
                Self.calendarLog.info("calendar \(id.uuidString.prefix(8), privacy: .public): \(events.count, privacy: .public) events")
            case .failure(let error):
                Self.calendarLog.error("calendar \(id.uuidString.prefix(8), privacy: .public): reading failed: \(String(describing: error), privacy: .public)")
                if force { show(error) }
            }
        }
        calendarEventsRange = start...end
    }

    /// Answers an event: through the account's calendar when it came from there, otherwise
    /// with a reply to the invitation email.
    public func respond(to item: AgendaItem, with response: CalendarInvite.Response) {
        let previous = rsvps[item.id]
        switch item.source {
        case .account(let accountID, let eventID):
            guard let account = account(accountID) else { return }
            rsvps[eventKey(item)] = response
            Task {
                do {
                    guard let reader = try await calendarAdapter(for: account) as? any CalendarReading else { return }
                    try await reader.respond(toEvent: eventID, with: response)
                    if var events = calendarEvents[accountID], let index = events.firstIndex(where: { $0.id == eventID }) {
                        events[index].response = response
                        calendarEvents[accountID] = events
                    }
                    notice = Notice(text: String(localized: "Replied \(response.shortTitle) to “\(item.title)”"))
                } catch {
                    rsvps[eventKey(item)] = previous
                    show(error)
                }
            }
        case .invite(let threadID, _):
            Task {
                guard let thread = await invitationThread(threadID) else {
                    notice = Notice(text: String(localized: "The invitation for “\(item.title)” isn't in your inbox anymore."))
                    return
                }
                let found = await askContext([thread]).first?.1 ?? [:]
                guard let invite = thread.messages.reversed().compactMap({ found[$0.id]?.invite }).first(where: { $0.method != "REPLY" }) else {
                    notice = Notice(text: String(localized: "The invitation for “\(item.title)” couldn't be read."))
                    return
                }
                respond(to: invite, in: thread, with: response)
            }
        }
    }

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
    }

    /// Opens the email an invitation came in, wherever it is now, titled with the meeting.
    public func showInvitation(threadID: String, title: String? = nil) {
        Task {
            guard let thread = await invitationThread(threadID) else {
                notice = Notice(text: String(localized: "The invitation for “\(title ?? "")” isn't in your inbox anymore."))
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
        case .accepted: String(localized: "Yes", comment: "Going to a meeting")
        case .tentative: String(localized: "Maybe", comment: "Going to a meeting")
        case .declined: String(localized: "No", comment: "Going to a meeting")
        }
    }
}
