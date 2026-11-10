import Foundation

/// The automatic emails calendars send about a meeting: an answer to an invitation ("Declined:
/// Second-round interview") or a cancellation. Outlook sends them over IMAP as text with a long
/// web link instead of calendar data, which reads as noise; Margin shows them as a small card.
public struct MeetingNotice: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case accepted, tentative, declined, cancelled }

    public var kind: Kind
    /// The meeting's title, without the prefix.
    public var title: String
    /// Where the meeting opens on the web (Outlook on the web, Google Calendar), when given.
    public var link: URL?

    /// Subject prefixes, in the languages Margin speaks.
    static let prefixes: [(String, Kind)] = [
        ("accepted:", .accepted), ("tentatively accepted:", .tentative), ("tentative:", .tentative),
        ("declined:", .declined), ("canceled:", .cancelled), ("cancelled:", .cancelled), ("canceled event:", .cancelled),
        ("geaccepteerd:", .accepted), ("voorlopig:", .tentative), ("voorlopig geaccepteerd:", .tentative),
        ("afgewezen:", .declined), ("geweigerd:", .declined), ("geannuleerd:", .cancelled),
        ("zugesagt:", .accepted), ("angenommen:", .accepted), ("mit vorbehalt:", .tentative), ("abgelehnt:", .declined),
        ("abgesagt:", .cancelled), ("accepté:", .accepted), ("accepté :", .accepted), ("provisoire:", .tentative),
        ("refusé:", .declined), ("refusé :", .declined), ("annulé:", .cancelled), ("annulé :", .cancelled),
    ]

    /// Recognises a notice from its subject; the body only supplies the web link.
    public static func detect(subject: String, text: String) -> MeetingNotice? {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard let (prefix, kind) = prefixes.sorted(by: { $0.0.count > $1.0.count }).first(where: { lower.hasPrefix($0.0) }) else { return nil }
        var title = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if title.hasSuffix(".") { title.removeLast() }
        guard !title.isEmpty else { return nil }
        return MeetingNotice(kind: kind, title: title, link: webLink(in: text))
    }

    /// Whether a subject alone marks an automatic meeting notice (for sorting).
    public static func isNotice(subject: String) -> Bool {
        let lower = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return prefixes.contains { lower.hasPrefix($0.0) }
    }

    static func webLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let hosts = ["outlook.office365.com", "outlook.office.com", "outlook.live.com", "calendar.google.com"]
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let host = url.host()?.lowercased(), hosts.contains(where: { host.hasSuffix($0) }) else { continue }
            // Outlook's "change your settings" link isn't the meeting.
            if url.absoluteString.contains("path=/options") { continue }
            return url
        }
        return nil
    }
}
