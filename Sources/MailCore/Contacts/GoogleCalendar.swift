import Foundation

/// Meetings for a Google account: creating events (Google sends the invitations), who's free
/// when, and the organization's rooms. Listing rooms is only open to Workspace admins; everyone
/// else can still book a room by its address.
public struct GoogleCalendarClient: Sendable {
    public static let calendar = URL(string: "https://www.googleapis.com/calendar/v3")!
    public static let directory = URL(string: "https://admin.googleapis.com/admin/directory/v1")!

    let http: BearerHTTP

    public init(
        accessToken: String,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession
    ) {
        http = BearerHTTP(token: accessToken, send: send)
    }

    /// The organization's rooms, from the Workspace directory.
    public func rooms() async throws -> [MeetingRoom] {
        var rooms: [MeetingRoom] = []
        var token: String?
        var pages = 0
        repeat {
            var components = URLComponents(url: Self.directory.appending(path: "customer/my_customer/resources/calendars"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "maxResults", value: "500")] + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let data = try await http.data(
                for: try http.request(components.url!),
                forbidden: String(localized: "Only Google Workspace admins can list every room. Add a room by its address instead.")
            )
            let page = try BearerHTTP.decode(ResourcePage.self, from: data)
            rooms += (page.items ?? []).compactMap { item in
                guard let email = item.resourceEmail, item.resourceCategory != "OTHER" else { return nil }
                return MeetingRoom(email: email, name: item.generatedResourceName ?? item.resourceName ?? email,
                                   capacity: item.capacity, building: item.buildingId, floor: item.floorName)
            }
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 20
        var seen = Set<String>()
        return rooms.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// When each address is busy between `from` and `to`.
    public func busyTimes(for emails: [String], from: Date, to: Date) async throws -> [String: [BusyTime]] {
        let body: [String: Any] = [
            "timeMin": Self.stamp(from), "timeMax": Self.stamp(to),
            "items": emails.map { ["id": $0] },
        ]
        let data = try await http.data(for: try http.request(Self.calendar.appending(path: "freeBusy"), method: "POST", json: body))
        let answer = try BearerHTTP.decode(FreeBusy.self, from: data)
        var result: [String: [BusyTime]] = [:]
        for (id, calendar) in answer.calendars ?? [:] {
            result[id.lowercased()] = (calendar.busy ?? []).compactMap { span in
                guard let start = Self.parse(span.start), let end = Self.parse(span.end) else { return nil }
                return BusyTime(start: start, end: end)
            }
        }
        return result
    }

    /// Adds the meeting to the account's calendar and has Google send the invitations.
    public func createEvent(_ meeting: MeetingRequest) async throws {
        var attendees: [[String: Any]] = meeting.attendees.map { person in
            var entry: [String: Any] = ["email": person.address]
            if let name = person.name { entry["displayName"] = name }
            return entry
        }
        attendees += meeting.rooms.map { ["email": $0.email, "displayName": $0.name, "resource": true] }
        var body: [String: Any] = [
            "iCalUID": meeting.uid,
            "summary": meeting.title,
            "start": ["dateTime": Self.stamp(meeting.start)],
            "end": ["dateTime": Self.stamp(meeting.end)],
            "attendees": attendees,
        ]
        if !meeting.notes.isEmpty { body["description"] = meeting.notes }
        let place = meeting.rooms.isEmpty ? meeting.location : meeting.rooms.map(\.name).joined(separator: ", ")
        if let place, !place.isEmpty { body["location"] = place }
        var components = URLComponents(url: Self.calendar.appending(path: "calendars/primary/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        _ = try await http.data(for: try http.request(components.url!, method: "POST", json: body))
    }

    static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    struct ResourcePage: Decodable {
        var items: [Resource]?
        var nextPageToken: String?
    }

    struct Resource: Decodable {
        var resourceEmail: String?
        var resourceName: String?
        var generatedResourceName: String?
        var resourceCategory: String?
        var capacity: Int?
        var buildingId: String?
        var floorName: String?
    }

    struct FreeBusy: Decodable {
        var calendars: [String: Calendar]?
        struct Calendar: Decodable { var busy: [Span]? }
        struct Span: Decodable { var start: String?; var end: String? }
    }
}
