import Foundation

/// What Margin needs from an account's calendar, whoever provides it: Microsoft 365, Google, or
/// plain email invitations for every other account.
public protocol CalendarAdapter: Sendable {
    /// The organization's meeting rooms. Empty when the provider has none.
    func rooms() async throws -> [MeetingRoom]
    /// When each address (people or rooms) is taken. Empty when the provider can't tell.
    func busyTimes(for emails: [String], from: Date, to: Date) async throws -> [String: [BusyTime]]
    /// Sends the meeting's invitations.
    func createEvent(_ meeting: MeetingRequest) async throws
    /// Everyone on a meeting and how they've answered, straight from the calendar; nil when the
    /// provider can't tell (answers then come from reply emails).
    func attendees(ofEventWithUID uid: String) async throws -> [MeetingAttendee]?
}

/// Where contacts come from: an account, a CardDAV server, or the Contacts app.
public protocol ContactsAdapter: Sendable {
    func contacts() async throws -> [Contact]
}

extension MicrosoftGraphClient: CalendarAdapter, ContactsAdapter {}
extension GoogleCalendarClient: CalendarAdapter {}
extension GooglePeopleClient: ContactsAdapter {}

extension CardDAVClient: ContactsAdapter {
    public func contacts() async throws -> [Contact] { try await allContacts() }
}

/// Meetings for accounts without a calendar API: the invitation goes out as an email with an
/// iCalendar part, which every calendar app understands. Answers come back as reply emails.
public struct EmailCalendar: CalendarAdapter {
    let organizer: EmailAddress
    let send: @Sendable (Draft) async throws -> Void

    public init(organizer: EmailAddress, send: @escaping @Sendable (Draft) async throws -> Void) {
        self.organizer = organizer
        self.send = send
    }

    public func rooms() async throws -> [MeetingRoom] { [] }

    public func busyTimes(for emails: [String], from: Date, to: Date) async throws -> [String: [BusyTime]] { [:] }

    public func attendees(ofEventWithUID uid: String) async throws -> [MeetingAttendee]? { nil }

    public func createEvent(_ meeting: MeetingRequest) async throws {
        let rooms = meeting.rooms.map { EmailAddress(name: $0.name, address: $0.email) }
        var lines = [meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)]
        lines.append(meeting.start.formatted(date: .complete, time: .shortened) + " – " + meeting.end.formatted(date: .omitted, time: .shortened))
        if let place = meeting.location, !place.isEmpty { lines.append(place) }
        var draft = Draft(from: organizer, to: meeting.attendees + rooms, subject: meeting.title,
                          text: lines.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        draft.calendar = meeting.iCalendar()
        try await send(draft)
    }
}

// MARK: Answers from the calendars

extension MicrosoftGraphClient {
    /// The attendees of the event with this iCalendar UID, with their answers.
    public func attendees(ofEventWithUID uid: String) async throws -> [MeetingAttendee]? {
        var components = URLComponents(string: "\(Self.base)/me/events")!
        components.queryItems = [
            URLQueryItem(name: "$filter", value: "iCalUId eq '\(uid.replacingOccurrences(of: "'", with: "''"))'"),
            URLQueryItem(name: "$select", value: "attendees"),
        ]
        let data = try await http.data(for: http.request(components.url!))
        struct Page: Decodable { var value: [Event] }
        struct Event: Decodable { var attendees: [Attendee]? }
        struct Attendee: Decodable {
            var type: String?
            var status: Status?
            var emailAddress: Address?
            struct Status: Decodable { var response: String? }
            struct Address: Decodable { var name: String?; var address: String? }
        }
        guard let event = try BearerHTTP.decode(Page.self, from: data).value.first else { return nil }
        return (event.attendees ?? []).compactMap { entry in
            guard let address = entry.emailAddress?.address, EmailAddress.isValid(address) else { return nil }
            let kind: MeetingAttendee.Kind = entry.type == "resource" ? .room : entry.type == "optional" ? .optional : .required
            let response: CalendarInvite.Response? = switch entry.status?.response {
            case "accepted", "organizer": .accepted
            case "tentativelyAccepted": .tentative
            case "declined": .declined
            default: nil
            }
            return MeetingAttendee(address: EmailAddress(name: entry.emailAddress?.name, address: address), kind: kind, response: response)
        }
    }
}

extension GoogleCalendarClient {
    /// The attendees of the event with this iCalendar UID, with their answers.
    public func attendees(ofEventWithUID uid: String) async throws -> [MeetingAttendee]? {
        var components = URLComponents(url: Self.calendar.appending(path: "calendars/primary/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "iCalUID", value: uid)]
        let data = try await http.data(for: try http.request(components.url!))
        struct Page: Decodable { var items: [Event]? }
        struct Event: Decodable { var attendees: [Attendee]? }
        struct Attendee: Decodable {
            var email: String?
            var displayName: String?
            var resource: Bool?
            var optional: Bool?
            var responseStatus: String?
        }
        guard let event = try BearerHTTP.decode(Page.self, from: data).items?.first else { return nil }
        return (event.attendees ?? []).compactMap { entry in
            guard let address = entry.email, EmailAddress.isValid(address) else { return nil }
            let kind: MeetingAttendee.Kind = entry.resource == true ? .room : entry.optional == true ? .optional : .required
            let response: CalendarInvite.Response? = switch entry.responseStatus {
            case "accepted": .accepted
            case "tentative": .tentative
            case "declined": .declined
            default: nil
            }
            return MeetingAttendee(address: EmailAddress(name: entry.displayName, address: address), kind: kind, response: response)
        }
    }
}
