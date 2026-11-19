import Foundation

/// The automatic emails calendars send about a meeting: an answer to an invitation or a
/// cancellation, known from their calendar data. Their text is mostly a long web link, which
/// reads as noise; Margin shows them as a small card.
public struct MeetingNotice: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case accepted, tentative, declined, cancelled }

    public var kind: Kind
    /// The meeting's title, without the prefix.
    public var title: String
    /// Where the meeting opens on the web (Outlook on the web, Google Calendar), when given.
    public var link: URL?

    /// An answer to a meeting or a cancellation, from the message's calendar data (METHOD REPLY
    /// or CANCEL); the text only supplies the web link. Nil for an invitation, or mail without
    /// calendar data: subjects aren't read.
    public static func detect(invite: CalendarInvite?, text: String) -> MeetingNotice? {
        guard let invite else { return nil }
        let title = invite.summary.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let kind: Kind
        switch invite.method.uppercased() {
        case "CANCEL": kind = .cancelled
        case "REPLY":
            switch invite.attendees.first?.response {
            case .accepted: kind = .accepted
            case .tentative: kind = .tentative
            case .declined: kind = .declined
            default: return nil
            }
        default: return nil
        }
        return MeetingNotice(kind: kind, title: title, link: webLink(in: text))
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
