import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// A new event for an account's calendar or this device's.
public struct EventDraft: Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    /// People to invite; the calendar sends them the invitation.
    public var invitees: [EmailAddress]
    /// Which of the calendars to put it in (an EventKit calendar identifier for this device's);
    /// nil for the main or default one.
    public var calendar: String?
    /// Give it a video call from the account's own service (Teams, Meet), with its join link.
    public var videoCall: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
                notes: String? = nil, invitees: [EmailAddress] = [], calendar: String? = nil, videoCall: Bool = false) {
        self.calendar = calendar
        self.videoCall = videoCall
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.invitees = invitees
    }
}

/// What to change on an event; nil leaves that part as it is.
public struct EventChanges: Hashable, Sendable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var location: String?
    public var notes: String?
    /// Whether the event is all day, so a new start and end are written as dates.
    public var isAllDay: Bool
    /// Add a video call from the account's own service to an event that has none.
    public var addVideoCall: Bool

    public init(title: String? = nil, start: Date? = nil, end: Date? = nil, location: String? = nil,
                notes: String? = nil, isAllDay: Bool = false, addVideoCall: Bool = false) {
        self.addVideoCall = addVideoCall
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.isAllDay = isAllDay
    }
}

/// For a repeating event: only the occurrence, or the whole series. A new time for the series
/// moves it by as much as this occurrence (which started at `occurrenceStart`) moved.
public enum RepeatScope: Hashable, Sendable {
    case thisEvent
    case allEvents(occurrenceStart: Date)
}

public enum CalendarWritingError: LocalizedError {
    case notFound, readOnly, noVideoCalls

    public var errorDescription: String? {
        switch self {
        case .noVideoCalls: String(localized: "This calendar can't add video calls.")
        case .notFound: String(localized: "That event isn't in the calendar anymore.")
        case .readOnly: String(localized: "That calendar can't be changed.")
        }
    }
}

/// Adding, changing and removing events, for calendars with an API. Guests are told by the
/// calendar itself (Exchange always; Google when `notify` is on).
public protocol CalendarWriting: Sendable {
    func addEvent(_ draft: EventDraft, notify: Bool) async throws -> CalendarEvent
    func updateEvent(id: String, _ changes: EventChanges, scope: RepeatScope, notify: Bool) async throws -> CalendarEvent
    func deleteEvent(id: String, scope: RepeatScope, notify: Bool) async throws
    /// The video call service new events can get (“Microsoft Teams”, “Google Meet”), nil when none.
    func videoCallService() async throws -> String?
}

extension CalendarWriting {
    /// One event, or one occurrence of a repeating one.
    public func updateEvent(id: String, _ changes: EventChanges, notify: Bool) async throws -> CalendarEvent {
        try await updateEvent(id: id, changes, scope: .thisEvent, notify: notify)
    }

    public func deleteEvent(id: String, notify: Bool) async throws {
        try await deleteEvent(id: id, scope: .thisEvent, notify: notify)
    }
}

extension EventChanges {
    /// The same changes for the series, whose first event starts at `seriesStart`: new times
    /// move it by as much as the occurrence moved.
    public func forSeries(starting seriesStart: Date, occurrenceStart: Date) -> EventChanges {
        var copy = self
        let shift = seriesStart.timeIntervalSince(occurrenceStart)
        copy.start = start?.addingTimeInterval(shift)
        copy.end = end?.addingTimeInterval(shift)
        return copy
    }
}

extension MicrosoftGraphClient: CalendarWriting {
    public func addEvent(_ draft: EventDraft, notify: Bool) async throws -> CalendarEvent {
        var body = Self.eventBody(EventChanges(title: draft.title, start: draft.start, end: draft.end, location: draft.location ?? "",
                                               notes: draft.notes, isAllDay: draft.isAllDay))
        body["isAllDay"] = draft.isAllDay
        if draft.videoCall {
            body["isOnlineMeeting"] = true
            body["onlineMeetingProvider"] = try await meetingProvider()
        }
        body["attendees"] = draft.invitees.map { ["emailAddress": Self.address($0.address, name: $0.name), "type": "required"] }
        let path = draft.calendar.map { "/me/calendars/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0)/events" } ?? "/me/events"
        return try await event(from: request(URL(string: "\(Self.base)\(path)")!, method: "POST", json: body))
    }

    public func updateEvent(id: String, _ changes: EventChanges, scope: RepeatScope, notify: Bool) async throws -> CalendarEvent {
        if case .allEvents(let occurrenceStart) = scope, let series = try await seriesMaster(of: id) {
            return try await event(from: request(eventURL(series.id), method: "PATCH",
                                                 json: try await videoBody(changes.forSeries(starting: series.start, occurrenceStart: occurrenceStart))))
        }
        return try await event(from: request(eventURL(id), method: "PATCH", json: try await videoBody(changes)))
    }

    /// The fields for a change, with a video call added when asked.
    private func videoBody(_ changes: EventChanges) async throws -> [String: Any] {
        var body = Self.eventBody(changes)
        if changes.addVideoCall {
            body["isOnlineMeeting"] = true
            body["onlineMeetingProvider"] = try await meetingProvider()
        }
        return body
    }

    public func videoCallService() async throws -> String? {
        switch try await meetingProviderIfAny() {
        case "teamsForBusiness": "Microsoft Teams"
        case "skypeForBusiness", "skypeForConsumer": "Skype"
        default: nil
        }
    }

    /// The calendar's own online meeting service: its default, else the first it allows.
    func meetingProvider() async throws -> String {
        guard let provider = try await meetingProviderIfAny() else { throw CalendarWritingError.noVideoCalls }
        return provider
    }

    private func meetingProviderIfAny() async throws -> String? {
        struct Calendar: Decodable {
            var defaultOnlineMeetingProvider: String?
            var allowedOnlineMeetingProviders: [String]?
        }
        var components = URLComponents(string: "\(Self.base)/me/calendar")!
        components.queryItems = [URLQueryItem(name: "$select", value: "defaultOnlineMeetingProvider,allowedOnlineMeetingProviders")]
        let calendar = try BearerHTTP.decode(Calendar.self, from: try await http.data(for: http.request(components.url!)))
        let usable = { (name: String?) in name.map { !$0.isEmpty && $0 != "unknown" } ?? false }
        if usable(calendar.defaultOnlineMeetingProvider) { return calendar.defaultOnlineMeetingProvider }
        return calendar.allowedOnlineMeetingProviders?.first(where: { usable($0) })
    }

    public func deleteEvent(id: String, scope: RepeatScope, notify: Bool) async throws {
        var target = id
        if case .allEvents = scope, let series = try await seriesMaster(of: id) { target = series.id }
        _ = try await http.data(for: http.request(eventURL(target), method: "DELETE"))
    }

    /// The series an occurrence belongs to, with the series' own start; nil when it doesn't repeat.
    func seriesMaster(of eventID: String) async throws -> (id: String, start: Date)? {
        struct Event: Decodable {
            var seriesMasterId: String?
            var start: Moment?
            var isAllDay: Bool?
            struct Moment: Decodable { var dateTime: String }
        }
        func read(_ id: String) async throws -> Event {
            var components = URLComponents(url: eventURL(id), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "$select", value: "seriesMasterId,start,isAllDay")]
            var request = try http.request(components.url!)
            request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
            return try BearerHTTP.decode(Event.self, from: try await http.data(for: request))
        }
        guard let masterID = try await read(eventID).seriesMasterId else { return nil }
        let master = try await read(masterID)
        guard let text = master.start?.dateTime, let start = CalendarDates.graph(text, allDay: master.isAllDay ?? false) else { return nil }
        return (masterID, start)
    }

    private func eventURL(_ id: String) -> URL {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        return URL(string: "\(Self.base)/me/events/\(encoded)")!
    }

    private func request(_ url: URL, method: String, json: [String: Any]) throws -> URLRequest {
        var request = try http.request(url, method: method, json: json)
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        return request
    }

    private func event(from request: URLRequest) async throws -> CalendarEvent {
        let data = try await http.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let page = try? JSONSerialization.data(withJSONObject: ["value": [object]]),
              let event = try Self.events(from: page).first else {
            throw MailError.protocolViolation(String(localized: "The answer couldn't be read."))
        }
        return event
    }

    /// Graph's fields for the parts that change. All-day events are written as local midnights
    /// in this device's time zone, which Graph requires for them.
    static func eventBody(_ changes: EventChanges) -> [String: Any] {
        var body: [String: Any] = [:]
        if let title = changes.title { body["subject"] = title }
        if let location = changes.location { body["location"] = ["displayName": location] }
        if let notes = changes.notes { body["body"] = ["contentType": "text", "content": notes] }
        func moment(_ date: Date) -> [String: String] {
            changes.isAllDay
                ? ["dateTime": CalendarDates.localDayStamp(date) + "T00:00:00", "timeZone": TimeZone.current.identifier]
                : ["dateTime": graphDate(date), "timeZone": "UTC"]
        }
        // A new time can turn an event into an all-day one or back.
        if changes.start != nil { body["isAllDay"] = changes.isAllDay }
        if let start = changes.start { body["start"] = moment(start) }
        if let end = changes.end { body["end"] = moment(end) }
        return body
    }
}

extension GoogleCalendarClient: CalendarWriting {
    public func addEvent(_ draft: EventDraft, notify: Bool) async throws -> CalendarEvent {
        var body = Self.eventBody(EventChanges(title: draft.title, start: draft.start, end: draft.end, location: draft.location,
                                               notes: draft.notes, isAllDay: draft.isAllDay))
        if !draft.invitees.isEmpty {
            body["attendees"] = draft.invitees.map { person -> [String: Any] in
                var entry: [String: Any] = ["email": person.address]
                if let name = person.name { entry["displayName"] = name }
                return entry
            }
        }
        if draft.videoCall { body["conferenceData"] = Self.newMeet() }
        return try await event(from: request(Self.calendar.appending(path: "calendars/\(draft.calendar ?? "primary")/events"), method: "POST", json: body,
                                             notify: notify, conference: draft.videoCall))
    }

    public func updateEvent(id: String, _ changes: EventChanges, scope: RepeatScope, notify: Bool) async throws -> CalendarEvent {
        if case .allEvents(let occurrenceStart) = scope, let series = try await series(of: id) {
            return try await event(from: request(eventURL(series.id), method: "PATCH",
                                                 json: Self.videoBody(changes.forSeries(starting: series.start, occurrenceStart: occurrenceStart)),
                                                 notify: notify, conference: changes.addVideoCall))
        }
        return try await event(from: request(eventURL(id), method: "PATCH", json: Self.videoBody(changes), notify: notify,
                                             conference: changes.addVideoCall))
    }

    public func deleteEvent(id: String, scope: RepeatScope, notify: Bool) async throws {
        var target = id
        if case .allEvents = scope, let series = try await series(of: id) { target = series.id }
        _ = try await http.data(for: request(eventURL(target), method: "DELETE", json: nil, notify: notify))
    }

    /// The series an occurrence belongs to (`recurringEventId`), with its first start.
    func series(of eventID: String) async throws -> (id: String, start: Date)? {
        struct Event: Decodable {
            var recurringEventId: String?
            var start: Moment?
            struct Moment: Decodable { var dateTime: String?; var date: String? }
        }
        func read(_ id: String) async throws -> Event {
            try BearerHTTP.decode(Event.self, from: try await http.data(for: try http.request(eventURL(id))))
        }
        guard let seriesID = try await read(eventID).recurringEventId else { return nil }
        let master = try await read(seriesID)
        guard let start = CalendarDates.google(master.start?.dateTime, date: master.start?.date) else { return nil }
        return (seriesID, start)
    }

    private func eventURL(_ id: String) -> URL {
        Self.calendar.appending(path: "calendars/primary/events/\(id)")
    }

    public func videoCallService() async throws -> String? { "Google Meet" }

    /// Asks Google to make a Meet call for the event; its link comes back on the event.
    static func newMeet() -> [String: Any] {
        ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
    }

    public static func videoBody(_ changes: EventChanges) -> [String: Any] {
        var body = eventBody(changes)
        if changes.addVideoCall { body["conferenceData"] = newMeet() }
        return body
    }

    /// `conference` lets Google read and make the event's video call (`conferenceDataVersion`).
    private func request(_ url: URL, method: String, json: [String: Any]?, notify: Bool, conference: Bool = false) throws -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: notify ? "all" : "none")]
        if conference { components.queryItems?.append(URLQueryItem(name: "conferenceDataVersion", value: "1")) }
        return try http.request(components.url!, method: method, json: json)
    }

    private func event(from request: URLRequest) async throws -> CalendarEvent {
        let data = try await http.data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let page = try? JSONSerialization.data(withJSONObject: ["items": [object]]),
              let event = try Self.events(from: page).first else {
            throw MailError.protocolViolation(String(localized: "The answer couldn't be read."))
        }
        return event
    }

    /// Google's fields for the parts that change; all-day events by date, the end day not included.
    static func eventBody(_ changes: EventChanges) -> [String: Any] {
        var body: [String: Any] = [:]
        if let title = changes.title { body["summary"] = title }
        if let location = changes.location { body["location"] = location }
        if let notes = changes.notes { body["description"] = notes }
        func moment(_ date: Date) -> [String: Any] {
            changes.isAllDay ? ["date": CalendarDates.localDayStamp(date), "dateTime": NSNull()] : ["dateTime": stamp(date), "date": NSNull()]
        }
        if let start = changes.start { body["start"] = moment(start) }
        if let end = changes.end { body["end"] = moment(end) }
        return body
    }
}

extension CalendarDates {
    /// "2026-11-12" for the day a moment falls on here.
    static func localDayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: This device's Calendar app

extension DeviceCalendar: CalendarWriting {
    /// Guests can't be invited through EventKit; `notify` doesn't apply.
    public func addEvent(_ draft: EventDraft, notify: Bool) async throws -> CalendarEvent {
        #if canImport(EventKit)
        let event = EKEvent(eventStore: store)
        event.calendar = draft.calendar.flatMap(store.calendar(withIdentifier:)) ?? store.defaultCalendarForNewEvents
        guard event.calendar?.allowsContentModifications == true else { throw CalendarWritingError.readOnly }
        event.title = draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = draft.isAllDay ? draft.end.addingTimeInterval(-1) : draft.end
        if let location = draft.location, !location.isEmpty { event.location = location }
        if let notes = draft.notes, !notes.isEmpty { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
        guard let made = Self.event(event) else { throw CalendarWritingError.notFound }
        return made
        #else
        throw CalendarWritingError.readOnly
        #endif
    }

    public func updateEvent(id: String, _ changes: EventChanges, scope: RepeatScope, notify: Bool) async throws -> CalendarEvent {
        #if canImport(EventKit)
        guard var event = occurrence(id) else { throw CalendarWritingError.notFound }
        guard event.calendar?.allowsContentModifications == true else { throw CalendarWritingError.readOnly }
        var change = changes
        var span = EKSpan.thisEvent
        if case .allEvents(let occurrenceStart) = scope, event.hasRecurrenceRules, let first = series(id), let firstStart = first.startDate {
            // EventKit changes a series from an occurrence on; the first one carries all of it.
            event = first
            change = changes.forSeries(starting: firstStart, occurrenceStart: occurrenceStart)
            span = .futureEvents
        }
        if let title = change.title { event.title = title }
        event.isAllDay = change.isAllDay
        if let start = change.start { event.startDate = start }
        if let end = change.end { event.endDate = change.isAllDay ? end.addingTimeInterval(-1) : end }
        if let location = change.location { event.location = location.isEmpty ? nil : location }
        if let notes = change.notes { event.notes = notes.isEmpty ? nil : notes }
        try store.save(event, span: span, commit: true)
        guard let changed = Self.event(event) else { throw CalendarWritingError.notFound }
        return changed
        #else
        throw CalendarWritingError.readOnly
        #endif
    }

    public func deleteEvent(id: String, scope: RepeatScope, notify: Bool) async throws {
        #if canImport(EventKit)
        let all: Bool = if case .allEvents = scope { true } else { false }
        guard let event = all ? series(id) : occurrence(id) else { throw CalendarWritingError.notFound }
        guard event.calendar?.allowsContentModifications == true else { throw CalendarWritingError.readOnly }
        try store.remove(event, span: all ? .futureEvents : .thisEvent, commit: true)
        #endif
    }

    /// EventKit can't make video calls.
    public func videoCallService() async throws -> String? { nil }

    /// Calendars new events can go in, by account then name.
    public func writableCalendars() -> [DeviceCalendarInfo] {
        #if canImport(EventKit)
        guard Self.eventAccess() == .allowed else { return [] }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { DeviceCalendarInfo(title: $0.title, source: $0.source.title, color: Self.rgb($0.cgColor), identifier: $0.calendarIdentifier) }
        #else
        []
        #endif
    }

    /// The identifier of the calendar new events go in by default.
    public func defaultCalendarIdentifier() -> String? {
        #if canImport(EventKit)
        Self.eventAccess() == .allowed ? store.defaultCalendarForNewEvents?.calendarIdentifier : nil
        #else
        nil
        #endif
    }

    #if canImport(EventKit)
    /// The occurrence one of our ids names: `device:<identifier>|<start>`. A repeating event's
    /// occurrences share the identifier, so the start picks the right one.
    func occurrence(_ id: String) -> EKEvent? {
        guard let identifier = Self.eventIdentifier(in: id) else { return nil }
        let parts = id.split(separator: "|")
        guard parts.count == 2, let seconds = TimeInterval(parts[1]) else { return store.event(withIdentifier: identifier) }
        let start = Date(timeIntervalSince1970: seconds)
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(86_400), calendars: nil)
        return store.events(matching: predicate).first { $0.eventIdentifier == identifier && abs($0.startDate.timeIntervalSince(start)) < 1 }
            ?? store.event(withIdentifier: identifier)
    }

    /// The first occurrence, which stands for the whole series.
    func series(_ id: String) -> EKEvent? {
        Self.eventIdentifier(in: id).flatMap(store.event(withIdentifier:))
    }
    #endif
}
