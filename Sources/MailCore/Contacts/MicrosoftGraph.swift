import Foundation

/// Contacts, meeting rooms, free/busy and new meetings from a Microsoft 365 or Outlook.com account,
/// through Microsoft Graph. The caller signs in and passes the access token.
public struct MicrosoftGraphClient: Sendable {
    public static let base = URL(string: "https://graph.microsoft.com/v1.0")!
    /// The most contacts read from one account; address completion needs no more.
    public static let contactLimit = 5000

    let http: BearerHTTP

    public init(
        accessToken: String,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = BearerHTTP.urlSession
    ) {
        http = BearerHTTP(token: accessToken, send: send)
    }

    // MARK: Contacts

    /// The account's contacts, then the people it works with (directory colleagues included),
    /// one entry per address.
    public func contacts() async throws -> [Contact] {
        let saved: [GraphContact] = try await pages(
            "\(Self.base)/me/contacts?$select=id,displayName,emailAddresses,companyName&$top=500")
        let people: [GraphPerson] = try await pages(
            "\(Self.base)/me/people?$top=200&$select=id,displayName,scoredEmailAddresses,companyName")
        let all = saved.map {
            Contact(id: "microsoft:\($0.id)", name: $0.displayName, emails: $0.emailAddresses?.compactMap(\.address) ?? [],
                    organization: $0.companyName, source: .microsoft)
        } + people.map {
            Contact(id: "microsoft:\($0.id)", name: $0.displayName, emails: $0.scoredEmailAddresses?.compactMap(\.address) ?? [],
                    organization: $0.companyName, source: .microsoft)
        }
        return Contact.mergedByEmail(all)
    }

    /// People in the organization (and the person's own circle) matching what's typed, best
    /// first: Graph's people search, which covers the whole directory, not just the 200 people
    /// read ahead.
    public func searchPeople(_ text: String, limit: Int = 8) async throws -> [EmailAddress] {
        let query = text.replacingOccurrences(of: "\"", with: "")
        var components = URLComponents(url: Self.base.appending(path: "me/people"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "$search", value: "\"\(query)\""),
            URLQueryItem(name: "$top", value: String(limit)),
            URLQueryItem(name: "$select", value: "displayName,scoredEmailAddresses"),
        ]
        guard let url = components.url else { return [] }
        let page = try BearerHTTP.decode(GraphPage<GraphPerson>.self, from: try await http.data(for: http.request(url)))
        return page.value.flatMap { person in
            (person.scoredEmailAddresses ?? []).compactMap(\.address).filter(EmailAddress.isValid)
                .map { EmailAddress(name: person.displayName, address: $0) }
        }
    }

    /// Everyone in the organization's directory whose name or address starts with what's typed,
    /// whether or not you've written to them. Needs User.ReadBasic.All; personal Microsoft
    /// accounts have no directory, which returns nothing.
    public func searchUsers(_ text: String, limit: Int = 8) async throws -> [EmailAddress] {
        let query = text.replacingOccurrences(of: "\"", with: "")
        var components = URLComponents(url: Self.base.appending(path: "users"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "$search", value: "\"displayName:\(query)\" OR \"mail:\(query)\" OR \"userPrincipalName:\(query)\""),
            URLQueryItem(name: "$top", value: String(limit)),
            URLQueryItem(name: "$select", value: "displayName,mail,userPrincipalName"),
            URLQueryItem(name: "$count", value: "true"),
        ]
        guard let url = components.url else { return [] }
        var request = try http.request(url)
        // Directory search only works with eventual consistency.
        request.setValue("eventual", forHTTPHeaderField: "ConsistencyLevel")
        let (data, response) = try await http.response(for: request)
        // No directory (personal account) or no permission yet: nothing to add.
        if [400, 401, 403, 404].contains(response.statusCode) { return [] }
        try http.check(data, response)
        let page = try BearerHTTP.decode(GraphPage<GraphUser>.self, from: data)
        return page.value.compactMap { user in
            guard let address = user.mail ?? user.userPrincipalName, EmailAddress.isValid(address) else { return nil }
            return EmailAddress(name: user.displayName, address: address)
        }
    }

    // MARK: Rooms

    /// The organization's bookable meeting rooms, by name.
    public func rooms() async throws -> [MeetingRoom] {
        var rooms: [MeetingRoom] = []
        var next = URL(string: "\(Self.base)/places/microsoft.graph.room?$top=500")
        var pageCount = 0
        while let url = next, pageCount < 20 {
            let (data, response) = try await http.response(for: http.request(url))
            if response.statusCode == 403 || response.statusCode == 404 {
                // Older tenants and personal accounts have no places directory.
                return try await roomLists()
            }
            try http.check(data, response, forbidden: Self.roomsForbidden)
            let page = try BearerHTTP.decode(GraphPage<GraphPlace>.self, from: data)
            rooms += page.value.compactMap { place in
                guard let email = place.emailAddress, EmailAddress.isValid(email) else { return nil }
                return MeetingRoom(email: email, name: place.displayName ?? email, capacity: place.capacity,
                                   building: place.building, floor: place.floorLabel ?? place.floorNumber.map(String.init))
            }
            next = page.nextLink.flatMap(URL.init(string:))
            pageCount += 1
        }
        return Self.sorted(rooms)
    }

    func roomLists() async throws -> [MeetingRoom] {
        let url = URL(string: "https://graph.microsoft.com/beta/me/findRooms")!
        let (data, response) = try await http.response(for: http.request(url))
        try http.check(data, response, forbidden: Self.roomsForbidden)
        let page = try BearerHTTP.decode(GraphPage<GraphFoundRoom>.self, from: data)
        return Self.sorted(page.value.compactMap { room in
            guard let email = room.address, EmailAddress.isValid(email) else { return nil }
            return MeetingRoom(email: email, name: room.name ?? email)
        })
    }

    static var roomsForbidden: String {
        String(localized: "Your organization hasn't allowed Margin to list meeting rooms.")
    }

    static func sorted(_ rooms: [MeetingRoom]) -> [MeetingRoom] {
        var seen = Set<String>()
        return rooms.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Free/busy

    /// When each person or room is taken between `from` and `to`, keyed by lowercased address.
    public func busyTimes(for emails: [String], from: Date, to: Date) async throws -> [String: [BusyTime]] {
        guard !emails.isEmpty else { return [:] }
        let body: [String: Any] = [
            "schedules": emails,
            "startTime": ["dateTime": Self.graphDate(from), "timeZone": "UTC"],
            "endTime": ["dateTime": Self.graphDate(to), "timeZone": "UTC"],
            "availabilityViewInterval": 15,
        ]
        var request = try http.request(URL(string: "\(Self.base)/me/calendar/getSchedule")!, method: "POST", json: body)
        request.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        let data = try await http.data(for: request)
        let page = try BearerHTTP.decode(GraphPage<GraphSchedule>.self, from: data)
        var result: [String: [BusyTime]] = [:]
        for schedule in page.value {
            let key = schedule.scheduleId.lowercased()
            let busy = (schedule.scheduleItems ?? []).compactMap { item -> BusyTime? in
                guard item.status?.lowercased() != "free",
                      let start = Self.parseGraphDate(item.start), let end = Self.parseGraphDate(item.end), start < end
                else { return nil }
                return BusyTime(start: start, end: end)
            }
            result[key, default: []] += busy.sorted { $0.start < $1.start }
        }
        return result
    }

    // MARK: Meetings

    /// Puts the meeting on the account's calendar; Exchange sends the invitations and books the rooms.
    public func createEvent(_ meeting: MeetingRequest) async throws {
        let place = meeting.rooms.isEmpty ? (meeting.location ?? "") : meeting.rooms.map(\.name).joined(separator: ", ")
        var attendees: [[String: Any]] = meeting.attendees.map {
            ["emailAddress": Self.address($0.address, name: $0.name), "type": "required"]
        }
        attendees += meeting.rooms.map { ["emailAddress": Self.address($0.email, name: $0.name), "type": "resource"] }
        var body: [String: Any] = [
            "subject": meeting.title,
            "body": ["contentType": "text", "content": meeting.notes],
            "start": ["dateTime": Self.graphDate(meeting.start), "timeZone": "UTC"],
            "end": ["dateTime": Self.graphDate(meeting.end), "timeZone": "UTC"],
            "location": ["displayName": place],
            "attendees": attendees,
            "transactionId": meeting.uid,
        ]
        if !meeting.rooms.isEmpty {
            body["locations"] = meeting.rooms.map {
                ["displayName": $0.name, "locationEmailAddress": $0.email, "locationType": "conferenceRoom"]
            }
        }
        _ = try await http.data(for: http.request(URL(string: "\(Self.base)/me/events")!, method: "POST", json: body))
    }

    static func address(_ address: String, name: String?) -> [String: String] {
        var value = ["address": address]
        if let name { value["name"] = name }
        return value
    }

    // MARK: Paging and dates

    func pages<Item: Decodable>(_ first: String) async throws -> [Item] {
        var items: [Item] = []
        var next = URL(string: first)
        var pageCount = 0
        while let url = next, items.count < Self.contactLimit, pageCount < 100 {
            let page = try BearerHTTP.decode(GraphPage<Item>.self, from: try await http.data(for: http.request(url)))
            items += page.value
            next = page.nextLink.flatMap(URL.init(string:))
            pageCount += 1
        }
        return Array(items.prefix(Self.contactLimit))
    }

    /// `2026-11-09T10:00:00` in UTC, the form Graph takes with a separate time zone.
    static func graphDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Graph answers `2026-11-09T10:00:00.0000000` in the zone it names; seven fraction digits
    /// don't fit a date format, so the fraction is cut off before parsing.
    static func parseGraphDate(_ value: GraphDateTime?) -> Date? {
        guard var text = value?.dateTime else { return nil }
        var zone = value?.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        if text.hasSuffix("Z") {
            text.removeLast()
            zone = TimeZone(identifier: "UTC")!
        }
        if let dot = text.firstIndex(of: ".") { text = String(text[..<dot]) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)
    }
}

// MARK: Graph shapes

struct GraphPage<Item: Decodable>: Decodable {
    var value: [Item]
    var nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

struct GraphAddress: Decodable {
    var address: String?
}

struct GraphContact: Decodable {
    var id: String
    var displayName: String?
    var emailAddresses: [GraphAddress]?
    var companyName: String?
}

struct GraphUser: Decodable {
    var displayName: String?
    var mail: String?
    var userPrincipalName: String?
}

struct GraphPerson: Decodable {
    var id: String
    var displayName: String?
    var scoredEmailAddresses: [GraphAddress]?
    var companyName: String?
}

struct GraphPlace: Decodable {
    var emailAddress: String?
    var displayName: String?
    var capacity: Int?
    var building: String?
    var floorLabel: String?
    var floorNumber: Int?
}

struct GraphFoundRoom: Decodable {
    var name: String?
    var address: String?
}

struct GraphDateTime: Decodable {
    var dateTime: String
    var timeZone: String?
}

struct GraphSchedule: Decodable {
    var scheduleId: String
    var scheduleItems: [Item]?

    struct Item: Decodable {
        var status: String?
        var start: GraphDateTime?
        var end: GraphDateTime?
    }
}

// MARK: Shared HTTP

/// JSON over HTTPS with a bearer token, for the account APIs behind contacts and rooms.
public struct BearerHTTP: Sendable {
    let token: String
    let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The real network.
    public static let urlSession: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw MailError.timedOut
        } catch let error as URLError {
            throw MailError.connectionFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MailError.protocolViolation(String(localized: "The answer wasn't HTTP."))
        }
        return (data, http)
    }

    func request(_ url: URL, method: String = "GET", json: Any? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }

    /// The body of a successful answer; errors become `MailError`.
    func data(for request: URLRequest, forbidden: String? = nil) async throws -> Data {
        let (data, response) = try await send(request)
        try check(data, response, forbidden: forbidden)
        return data
    }

    func check(_ data: Data, _ response: HTTPURLResponse, forbidden: String? = nil) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw MailError.authenticationFailed(String(localized: "Sign in to this account again."))
        case 403: throw MailError.authenticationFailed(forbidden ?? String(localized: "This account didn't allow Margin access."))
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
            throw MailError.serverRejected(message ?? "HTTP \(response.statusCode)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MailError.protocolViolation(String(localized: "The answer couldn't be read."))
        }
    }

    struct ErrorBody: Decodable {
        var error: Detail
        struct Detail: Decodable { var message: String? }
    }
}

extension Contact {
    /// One entry per address: earlier contacts win, later ones keep only addresses not seen yet
    /// and are dropped when none are left.
    static func mergedByEmail(_ contacts: [Contact]) -> [Contact] {
        var seen = Set<String>()
        return contacts.compactMap { contact in
            var contact = contact
            contact.emails = contact.emails.filter { seen.insert($0.lowercased()).inserted }
            return contact.emails.isEmpty ? nil : contact
        }
    }
}
