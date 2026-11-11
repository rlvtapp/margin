import Foundation

/// An event read from an account's own calendar (Microsoft 365 or Google), for the Calendar
/// view and Ask. Invitations found in mail are added to these by the app.
public struct CalendarEvent: Codable, Hashable, Identifiable, Sendable {
    /// The provider's id, used to answer the event.
    public var id: String
    /// The iCalendar UID, shared with the invitation email, so the two can be matched.
    public var uid: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var joinURL: URL?
    public var organizer: String?
    /// Your own answer; nil when you haven't answered or you organized it.
    public var response: CalendarInvite.Response?
    public var isOrganizer: Bool
    public var isCancelled: Bool
    public var repeats: Bool
    /// Everyone invited, with their answers when the calendar knows them.
    public var attendees: [MeetingAttendee] = []

    public init(id: String, uid: String? = nil, title: String, start: Date, end: Date, isAllDay: Bool = false,
                location: String? = nil, joinURL: URL? = nil, organizer: String? = nil,
                response: CalendarInvite.Response? = nil, isOrganizer: Bool = false, isCancelled: Bool = false, repeats: Bool = false) {
        self.id = id
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.joinURL = joinURL
        self.organizer = organizer
        self.response = response
        self.isOrganizer = isOrganizer
        self.isCancelled = isCancelled
        self.repeats = repeats
    }
}

/// Reading events and answering them, for calendars with an API.
public protocol CalendarReading: Sendable {
    /// Events between two moments, repeating ones as single occurrences.
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
    /// Answers an event in your calendar; the organizer is told.
    func respond(toEvent id: String, with response: CalendarInvite.Response) async throws
}

extension MicrosoftGraphClient: CalendarReading {
    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var components = URLComponents(string: "\(Self.base)/me/calendarView")!
        let iso = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "startDateTime", value: iso.string(from: start)),
            URLQueryItem(name: "endDateTime", value: iso.string(from: end)),
            URLQueryItem(name: "$top", value: "250"),
            URLQueryItem(name: "$orderby", value: "start/dateTime"),
            URLQueryItem(name: "$select", value: "id,iCalUId,subject,start,end,isAllDay,location,onlineMeeting,onlineMeetingUrl,organizer,responseStatus,isCancelled,isOrganizer,type,attendees"),
        ]
        var request = try http.request(components.url!)
        // Times in UTC, so they read the same everywhere.
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        let data = try await http.data(for: request, forbidden: String(localized: "This account didn't allow Margin to read its calendar."))
        return try Self.events(from: data)
    }

    static func events(from data: Data) throws -> [CalendarEvent] {
        struct Page: Decodable { var value: [Event] }
        struct Event: Decodable {
            var id: String
            var iCalUId: String?
            var subject: String?
            var start: Moment
            var end: Moment
            var isAllDay: Bool?
            var location: Place?
            var onlineMeeting: Online?
            var onlineMeetingUrl: String?
            var organizer: Organizer?
            var responseStatus: Status?
            var isCancelled: Bool?
            var isOrganizer: Bool?
            var type: String?
            var attendees: [Attendee]?
            struct Attendee: Decodable { var type: String?; var status: Status?; var emailAddress: Address? }
            struct Moment: Decodable { var dateTime: String }
            struct Place: Decodable { var displayName: String? }
            struct Online: Decodable { var joinUrl: String? }
            struct Organizer: Decodable { var emailAddress: Address? }
            struct Address: Decodable { var name: String?; var address: String? }
            struct Status: Decodable { var response: String? }
        }
        return try BearerHTTP.decode(Page.self, from: data).value.compactMap { event in
            let allDay = event.isAllDay ?? false
            guard let start = CalendarDates.graph(event.start.dateTime, allDay: allDay),
                  let end = CalendarDates.graph(event.end.dateTime, allDay: allDay) else { return nil }
            let response: CalendarInvite.Response? = switch event.responseStatus?.response {
            case "accepted": .accepted
            case "tentativelyAccepted": .tentative
            case "declined": .declined
            default: nil
            }
            let join = event.onlineMeeting?.joinUrl ?? event.onlineMeetingUrl
            let place = event.location?.displayName.flatMap { $0.isEmpty ? nil : $0 }
            var result = CalendarEvent(id: event.id, uid: event.iCalUId, title: event.subject ?? String(localized: "Untitled event"),
                                       start: start, end: end, isAllDay: allDay, location: place, joinURL: join.flatMap(URL.init(string:)),
                                       organizer: event.organizer?.emailAddress?.name ?? event.organizer?.emailAddress?.address,
                                       response: response, isOrganizer: event.isOrganizer ?? false, isCancelled: event.isCancelled ?? false,
                                       repeats: event.type == "occurrence" || event.type == "exception")
            result.attendees = (event.attendees ?? []).compactMap { entry in
                guard let address = entry.emailAddress?.address, EmailAddress.isValid(address) else { return nil }
                let kind: MeetingAttendee.Kind = entry.type == "resource" ? .room : entry.type == "optional" ? .optional : .required
                let answer: CalendarInvite.Response? = switch entry.status?.response {
                case "accepted", "organizer": .accepted
                case "tentativelyAccepted": .tentative
                case "declined": .declined
                default: nil
                }
                return MeetingAttendee(address: EmailAddress(name: entry.emailAddress?.name, address: address), kind: kind, response: answer)
            }
            return result
        }
    }

    public func respond(toEvent id: String, with response: CalendarInvite.Response) async throws {
        let action = switch response {
        case .accepted: "accept"
        case .tentative: "tentativelyAccept"
        case .declined: "decline"
        }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        let url = URL(string: "\(Self.base)/me/events/\(encoded)/\(action)")!
        _ = try await http.data(for: try http.request(url, method: "POST", json: ["sendResponse": true]))
    }
}

extension GoogleCalendarClient: CalendarReading {
    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var components = URLComponents(url: Self.calendar.appending(path: "calendars/primary/events"), resolvingAgainstBaseURL: false)!
        let iso = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: iso.string(from: start)),
            URLQueryItem(name: "timeMax", value: iso.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        let data = try await http.data(for: try http.request(components.url!),
                                       forbidden: String(localized: "This account didn't allow Margin to read its calendar."))
        return try Self.events(from: data)
    }

    static func events(from data: Data) throws -> [CalendarEvent] {
        struct Page: Decodable { var items: [Event]? }
        struct Event: Decodable {
            var id: String
            var iCalUID: String?
            var summary: String?
            var status: String?
            var start: Moment?
            var end: Moment?
            var location: String?
            var hangoutLink: String?
            var conferenceData: Conference?
            var organizer: Person?
            var attendees: [Attendee]?
            var recurringEventId: String?
            struct Moment: Decodable { var dateTime: String?; var date: String? }
            struct Conference: Decodable { var entryPoints: [Entry]? }
            struct Entry: Decodable { var entryPointType: String?; var uri: String? }
            struct Person: Decodable { var email: String?; var displayName: String?; var `self`: Bool? }
            struct Attendee: Decodable {
                var `self`: Bool?
                var responseStatus: String?
                var email: String?
                var displayName: String?
                var resource: Bool?
                var optional: Bool?
            }
        }
        return try BearerHTTP.decode(Page.self, from: data).items?.compactMap { event in
            guard let startMoment = event.start, let start = CalendarDates.google(startMoment.dateTime, date: startMoment.date) else { return nil }
            let end = event.end.flatMap { CalendarDates.google($0.dateTime, date: $0.date) } ?? start.addingTimeInterval(3600)
            let mine = event.attendees?.first { $0.`self` == true }
            let response: CalendarInvite.Response? = switch mine?.responseStatus {
            case "accepted": .accepted
            case "tentative": .tentative
            case "declined": .declined
            default: nil
            }
            let join = event.hangoutLink ?? event.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
            var result = CalendarEvent(id: event.id, uid: event.iCalUID, title: event.summary ?? String(localized: "Untitled event"),
                                       start: start, end: end, isAllDay: startMoment.dateTime == nil, location: event.location,
                                       joinURL: join.flatMap(URL.init(string:)),
                                       organizer: event.organizer?.displayName ?? event.organizer?.email, response: response,
                                       isOrganizer: event.organizer?.`self` == true, isCancelled: event.status == "cancelled",
                                       repeats: event.recurringEventId != nil)
            result.attendees = (event.attendees ?? []).compactMap { entry in
                guard let address = entry.email, EmailAddress.isValid(address) else { return nil }
                let kind: MeetingAttendee.Kind = entry.resource == true ? .room : entry.optional == true ? .optional : .required
                let answer: CalendarInvite.Response? = switch entry.responseStatus {
                case "accepted": .accepted
                case "tentative": .tentative
                case "declined": .declined
                default: nil
                }
                return MeetingAttendee(address: EmailAddress(name: entry.displayName, address: address), kind: kind, response: answer)
            }
            return result
        } ?? []
    }

    /// Google has no answer call: your own attendee entry is changed and everyone is told.
    public func respond(toEvent id: String, with response: CalendarInvite.Response) async throws {
        let url = Self.calendar.appending(path: "calendars/primary/events/\(id)")
        let data = try await http.data(for: try http.request(url))
        guard var event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var attendees = event["attendees"] as? [[String: Any]],
              let index = attendees.firstIndex(where: { $0["self"] as? Bool == true }) else { return }
        attendees[index]["responseStatus"] = switch response {
        case .accepted: "accepted"
        case .tentative: "tentative"
        case .declined: "declined"
        }
        event = ["attendees": attendees]
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        _ = try await http.data(for: try http.request(components.url!, method: "PATCH", json: event))
    }
}

/// The date formats the calendar APIs use.
enum CalendarDates {
    /// Graph's "2026-11-12T09:00:00.0000000" in UTC; an all-day event's midnight is the local day.
    static func graph(_ text: String, allDay: Bool) -> Date? {
        let trimmed = String(text.prefix(19))
        if allDay { return localDay(String(trimmed.prefix(10))) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: trimmed)
    }

    /// Google's RFC 3339 time, or a date for all-day events.
    static func google(_ dateTime: String?, date: String?) -> Date? {
        if let dateTime {
            let formatter = ISO8601DateFormatter()
            if let parsed = formatter.date(from: dateTime) { return parsed }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateTime)
        }
        return date.flatMap(localDay)
    }

    /// "2026-11-12" as the start of that day here.
    static func localDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
