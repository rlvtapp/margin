import Foundation

/// Links between Margin and Daybook (docs/daybook.md): building the ones Margin opens in
/// Daybook, and reading the ones Daybook opens in Margin.
public enum DaybookLink {
    /// Shows a meeting in Daybook, or its day; with the invitation's text, Daybook can add it.
    public static func event(uid: String, start: Date?, ics: String? = nil) -> URL {
        var items = [URLQueryItem(name: "uid", value: uid)]
        if let start { items.append(URLQueryItem(name: "start", value: stamp(start))) }
        if let ics { items.append(URLQueryItem(name: "ics", value: base64URL(Data(ics.utf8)))) }
        return url("event", items)
    }

    /// Opens a new event in Daybook with these filled in.
    public static func new(title: String?, start: Date?, end: Date?, attendees: [String],
                           location: String?, notes: String?) -> URL {
        var items: [URLQueryItem] = []
        if let title, !title.isEmpty { items.append(URLQueryItem(name: "title", value: title)) }
        if let start { items.append(URLQueryItem(name: "start", value: stamp(start))) }
        if let end { items.append(URLQueryItem(name: "end", value: stamp(end))) }
        if !attendees.isEmpty { items.append(URLQueryItem(name: "attendees", value: attendees.joined(separator: ","))) }
        if let location, !location.isEmpty { items.append(URLQueryItem(name: "location", value: location)) }
        if let notes, !notes.isEmpty { items.append(URLQueryItem(name: "notes", value: notes)) }
        return url("new", items)
    }

    static func url(_ host: String, _ items: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "daybook"
        components.host = host
        components.queryItems = items.isEmpty ? nil : items
        // "+" means a space to some readers; keep it literal.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// What a `margin://` link from Daybook asks for.
public enum MarginLink: Equatable, Sendable {
    /// A new message.
    case compose(to: [String], cc: [String], subject: String?, body: String?)
    /// The email an invitation came in, by its iCalendar UID.
    case invite(uid: String)

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "margin",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        func list(_ name: String) -> [String] {
            (value(name) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter(EmailAddress.isValid)
        }
        switch components.host?.lowercased() {
        case "compose":
            self = .compose(to: list("to"), cc: list("cc"), subject: value("subject"), body: value("body"))
        case "invite":
            guard let uid = value("uid") else { return nil }
            self = .invite(uid: uid)
        default:
            return nil
        }
    }

    /// The same message as a mailto link, which compose already understands.
    public var mailto: URL? {
        guard case .compose(let to, let cc, let subject, let body) = self else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.joined(separator: ",")
        var items: [URLQueryItem] = []
        if !cc.isEmpty { items.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        if let subject { items.append(URLQueryItem(name: "subject", value: subject)) }
        if let body { items.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}
