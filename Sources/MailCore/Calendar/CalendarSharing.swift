import Foundation

/// People whose calendars this account can see: calendars others shared with you and you added.
/// Compare with suggests them first, since their busy times are sure to show.
public protocol CalendarSharing: Sendable {
    func sharedCalendarOwners() async throws -> [EmailAddress]
}

extension MicrosoftGraphClient: CalendarSharing {
    public func sharedCalendarOwners() async throws -> [EmailAddress] {
        let url = URL(string: "\(Self.base)/me/calendars?$select=name,owner,isDefaultCalendar&$top=100")!
        let data = try await http.data(for: try http.request(url),
                                       forbidden: String(localized: "This account didn't allow Margin to read its calendar."))
        return Self.sharedOwners(from: data)
    }

    static func sharedOwners(from data: Data) -> [EmailAddress] {
        struct Page: Decodable { var value: [Calendar] }
        struct Calendar: Decodable {
            struct Owner: Decodable { var name: String?; var address: String? }
            var owner: Owner?
            var isDefaultCalendar: Bool?
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        // Your own calendars have you as owner; the default one tells which address that is.
        let me = page.value.first { $0.isDefaultCalendar == true }?.owner?.address?.lowercased()
        var seen = Set<String>()
        return page.value.compactMap { calendar in
            guard let address = calendar.owner?.address, address.contains("@"), address.lowercased() != me,
                  seen.insert(address.lowercased()).inserted else { return nil }
            return EmailAddress(name: calendar.owner?.name, address: address)
        }
    }
}

extension GoogleCalendarClient: CalendarSharing {
    public func sharedCalendarOwners() async throws -> [EmailAddress] {
        var components = URLComponents(url: Self.calendar.appending(path: "users/me/calendarList"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "minAccessRole", value: "freeBusyReader"), URLQueryItem(name: "maxResults", value: "250")]
        let data = try await http.data(for: try http.request(components.url!),
                                       forbidden: String(localized: "This account didn't allow Margin to read its calendar."))
        return Self.sharedOwners(from: data)
    }

    static func sharedOwners(from data: Data) -> [EmailAddress] {
        struct Page: Decodable { var items: [Entry]? }
        struct Entry: Decodable {
            var id: String
            var summary: String?
            var summaryOverride: String?
            var primary: Bool?
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        // A person's calendar is listed under their address; holidays, birthdays and group
        // calendars live under calendar.google.com addresses and aren't people.
        return (page.items ?? []).compactMap { entry in
            guard entry.primary != true, entry.id.contains("@"), !entry.id.lowercased().hasSuffix("calendar.google.com") else { return nil }
            let name = entry.summaryOverride ?? entry.summary
            return EmailAddress(name: name == entry.id ? nil : name, address: entry.id)
        }
    }
}
