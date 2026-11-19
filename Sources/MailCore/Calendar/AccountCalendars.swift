import Foundation

/// One of the calendars in a mailbox: its own ("Calendar", "Birthdays", a team calendar) or one
/// someone shared with you. Each shows in the sidebar under its mailbox, to show or hide.
public struct AccountCalendar: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 0xRRGGBB, when the calendar has a colour of its own.
    public var color: UInt32?
    /// The one new events go in and invitations land in.
    public var isDefault: Bool
    /// Whether events in it can be changed from here.
    public var canEdit: Bool
    /// Whose it is, when someone else's (shared with you).
    public var owner: EmailAddress?

    public init(id: String, name: String, color: UInt32? = nil, isDefault: Bool = false, canEdit: Bool = false, owner: EmailAddress? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.isDefault = isDefault
        self.canEdit = canEdit
        self.owner = owner
    }

    /// "#RRGGBB" as 0xRRGGBB; nil for anything else (an automatic colour).
    static func rgb(_ hex: String?) -> UInt32? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }
}

/// A mailbox's calendars and the events in each, for mailboxes with more than one.
public protocol CalendarListing: Sendable {
    func calendars() async throws -> [AccountCalendar]
    func events(in calendar: AccountCalendar, from start: Date, to end: Date) async throws -> [CalendarEvent]
}

extension MicrosoftGraphClient: CalendarListing {
    public func calendars() async throws -> [AccountCalendar] {
        let url = URL(string: "\(Self.base)/me/calendars?$select=id,name,hexColor,isDefaultCalendar,canEdit,owner&$top=100")!
        let data = try await http.data(for: try http.request(url),
                                       forbidden: String(localized: "This account didn't allow Margin to read its calendar."))
        return Self.calendars(from: data)
    }

    static func calendars(from data: Data) -> [AccountCalendar] {
        struct Page: Decodable { var value: [Entry] }
        struct Entry: Decodable {
            struct Owner: Decodable { var name: String?; var address: String? }
            var id: String
            var name: String?
            var hexColor: String?
            var isDefaultCalendar: Bool?
            var canEdit: Bool?
            var owner: Owner?
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        let me = page.value.first { $0.isDefaultCalendar == true }?.owner?.address?.lowercased()
        return page.value.map { entry in
            let theirs = entry.owner?.address.flatMap { $0.lowercased() == me ? nil : EmailAddress(name: entry.owner?.name, address: $0) }
            return AccountCalendar(id: entry.id, name: entry.name ?? "", color: AccountCalendar.rgb(entry.hexColor),
                                   isDefault: entry.isDefaultCalendar == true, canEdit: entry.canEdit == true && theirs == nil, owner: theirs)
        }
    }

    public func events(in calendar: AccountCalendar, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let id = calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? calendar.id
        return try await calendarView("/me/calendars/\(id)/calendarView", from: start, to: end).map { calendar.tag($0) }
    }
}

extension GoogleCalendarClient: CalendarListing {
    public func calendars() async throws -> [AccountCalendar] {
        var components = URLComponents(url: Self.calendar.appending(path: "users/me/calendarList"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "minAccessRole", value: "reader"), URLQueryItem(name: "maxResults", value: "250")]
        let data = try await http.data(for: try http.request(components.url!),
                                       forbidden: String(localized: "This account didn't allow Margin to read its calendar."))
        return Self.calendars(from: data)
    }

    static func calendars(from data: Data) -> [AccountCalendar] {
        struct Page: Decodable { var items: [Entry]? }
        struct Entry: Decodable {
            var id: String
            var summary: String?
            var summaryOverride: String?
            var backgroundColor: String?
            var primary: Bool?
            var accessRole: String?
            var hidden: Bool?
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        return (page.items ?? []).filter { $0.hidden != true }.map { entry in
            let isPerson = entry.primary != true && entry.id.contains("@") && !entry.id.lowercased().hasSuffix("calendar.google.com")
            // Changes go to the main calendar only (`CalendarWriting`); the others are read here.
            return AccountCalendar(id: entry.id, name: entry.summaryOverride ?? entry.summary ?? entry.id,
                                   color: AccountCalendar.rgb(entry.backgroundColor), isDefault: entry.primary == true,
                                   canEdit: entry.primary == true, owner: isPerson ? EmailAddress(address: entry.id) : nil)
        }
    }

    public func events(in calendar: AccountCalendar, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let id = calendar.isDefault ? "primary"
            : (calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@"))) ?? calendar.id)
        return try await events(inCalendar: id, from: start, to: end).map { calendar.tag($0) }
    }
}

extension AccountCalendar {
    /// The event marked as in this calendar; one you can't change here stays unchangeable.
    func tag(_ event: CalendarEvent) -> CalendarEvent {
        var event = event
        event.calendarID = id
        event.calendarName = name
        event.calendarColor = color
        if !canEdit { event.canChange = false }
        return event
    }
}
