import Foundation

/// What a `margin://` link asks for.
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
