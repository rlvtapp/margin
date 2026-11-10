import Foundation

/// Reusable text for messages, with fill-ins: {first_name}, {name}, {my_name}, {date}.
public struct MailTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var subject: String
    public var body: String

    public init(name: String, subject: String = "", body: String) {
        self.name = name
        self.subject = subject
        self.body = body
    }

    /// The template with fill-ins replaced for this recipient and sender.
    public func filled(to recipient: EmailAddress?, from me: EmailAddress, date: Date = Date()) -> (subject: String, body: String) {
        let name = recipient?.displayName ?? ""
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let values = [
            "{first_name}": first, "{name}": name,
            "{my_name}": me.displayName, "{my_first_name}": me.displayName.split(separator: " ").first.map(String.init) ?? me.displayName,
            "{date}": date.formatted(date: .long, time: .omitted),
        ]
        func fill(_ text: String) -> String {
            values.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
        return (fill(subject), fill(body))
    }

    public static let examples = [
        MailTemplate(
            name: String(localized: "Thanks", comment: "Name of a starter reply template"),
            body: String(localized: "Hi {first_name},\n\nThanks for this, much appreciated.\n\n{my_first_name}", comment: "Starter template; keep the {…} fill-ins as they are")
        ),
        MailTemplate(
            name: String(localized: "Not now", comment: "Name of a starter reply template"),
            body: String(localized: "Hi {first_name},\n\nThanks for thinking of me. I can't take this on right now, but please keep me in mind for later.\n\nBest,\n{my_first_name}", comment: "Starter template; keep the {…} fill-ins as they are")
        ),
    ]
}
