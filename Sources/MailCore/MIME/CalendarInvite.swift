import Foundation

/// A meeting invitation from a `text/calendar` part (iCalendar, RFC 5545; iTIP, RFC 5546).
public struct CalendarInvite: Codable, Hashable, Sendable {
    public var uid: String
    public var method: String
    public var summary: String
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    public var location: String?
    public var organizer: EmailAddress?
    public var sequence: Int
    /// A video call link, from the event's conference fields, location or description.
    public var joinURL: URL?
    /// The original calendar text, for "Add to Calendar".
    public var raw: String
    /// Everyone on the invitation, with their answer as the sender knew it. In a REPLY, the one
    /// person answering.
    public var attendees: [MeetingAttendee] = []

    public var isCancelled: Bool { method.uppercased() == "CANCEL" }

    public static func parse(_ text: String) -> CalendarInvite? {
        let lines = unfold(text)
        guard let begin = lines.firstIndex(where: { $0.uppercased() == "BEGIN:VEVENT" }) else { return nil }
        let method = lines.first { $0.uppercased().hasPrefix("METHOD:") }.map { String($0.dropFirst(7)) } ?? "PUBLISH"
        var properties: [(name: String, params: [String: String], value: String)] = []
        for line in lines[(begin + 1)...] {
            if line.uppercased() == "END:VEVENT" { break }
            guard let colon = Self.valueColon(in: line) else { continue }
            let head = line[..<colon].split(separator: ";").map(String.init)
            var params: [String: String] = [:]
            for part in head.dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            properties.append((head.first?.uppercased() ?? "", params, unescape(String(line[line.index(after: colon)...]))))
        }
        func first(_ name: String) -> (params: [String: String], value: String)? {
            properties.first { $0.name == name }.map { ($0.params, $0.value) }
        }
        guard let uid = first("UID")?.value else { return nil }
        let start = first("DTSTART").map { parseDate($0.value, params: $0.params) }
        let end = first("DTEND").map { parseDate($0.value, params: $0.params) }
        let organizer = first("ORGANIZER").flatMap { entry -> EmailAddress? in
            let address = entry.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            return EmailAddress.isValid(address) ? EmailAddress(name: entry.params["CN"], address: address) : nil
        }
        let location = first("LOCATION")?.value
        let candidates = ["X-GOOGLE-CONFERENCE", "X-MICROSOFT-ONLINEMEETINGURL", "X-MICROSOFT-SKYPETEAMSMEETINGURL", "URL", "LOCATION", "DESCRIPTION"]
            .compactMap { first($0)?.value }
        let attendees = properties.filter { $0.name == "ATTENDEE" }.compactMap { entry -> MeetingAttendee? in
            let address = entry.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            guard EmailAddress.isValid(address) else { return nil }
            let type = entry.params["CUTYPE"]?.uppercased()
            let kind: MeetingAttendee.Kind = type == "ROOM" || type == "RESOURCE" ? .room
                : entry.params["ROLE"]?.uppercased() == "OPT-PARTICIPANT" ? .optional : .required
            return MeetingAttendee(address: EmailAddress(name: entry.params["CN"], address: address), kind: kind,
                                   response: Response(rawValue: entry.params["PARTSTAT"]?.uppercased() ?? ""))
        }
        return CalendarInvite(
            uid: uid, method: method.uppercased(), summary: first("SUMMARY")?.value ?? "Meeting",
            start: start?.date, end: end?.date, isAllDay: start?.allDay ?? false,
            location: location, organizer: organizer, sequence: Int(first("SEQUENCE")?.value ?? "") ?? 0,
            joinURL: candidates.lazy.compactMap(meetingLink).first, raw: text, attendees: attendees
        )
    }

    /// An iTIP REPLY saying whether `attendee` accepts, declines or might come.
    public func reply(from attendee: EmailAddress, status: Response, now: Date = Date()) -> String {
        let stamp = Self.utcStamp(now)
        var lines = [
            "BEGIN:VCALENDAR", "PRODID:-//Margin//Mail//EN", "VERSION:2.0", "METHOD:REPLY",
            "BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:\(stamp)", "SEQUENCE:\(sequence)", "SUMMARY:\(Self.escape(summary))",
        ]
        if let start { lines.append(isAllDay ? "DTSTART;VALUE=DATE:\(Self.dayStamp(start))" : "DTSTART:\(Self.utcStamp(start))") }
        if let end { lines.append(isAllDay ? "DTEND;VALUE=DATE:\(Self.dayStamp(end))" : "DTEND:\(Self.utcStamp(end))") }
        if let organizer { lines.append("ORGANIZER\(organizer.name.map { ";CN=\(Self.paramValue($0))" } ?? ""):mailto:\(organizer.address)") }
        lines.append("ATTENDEE;PARTSTAT=\(status.rawValue)\(attendee.name.map { ";CN=\(Self.paramValue($0))" } ?? ""):mailto:\(attendee.address)")
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public enum Response: String, Codable, Sendable, CaseIterable {
        case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED"
        public var verb: String {
            switch self {
            case .accepted: String(localized: "Accepted")
            case .tentative: String(localized: "Tentatively accepted")
            case .declined: String(localized: "Declined")
            }
        }
    }

    // MARK: Parsing helpers

    /// Lines continued with a leading space or tab are joined (RFC 5545 §3.1).
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    /// The colon after the property name and parameters; quoted parameter values may contain colons.
    static func valueColon(in line: String) -> String.Index? {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ":" && !quoted { return index }
        }
        return nil
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func paramValue(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "'"))\""
    }

    /// `20261112T090000Z` (UTC), `20261112T100000` with TZID or floating, `20261112` (all day).
    static func parseDate(_ value: String, params: [String: String]) -> (date: Date?, allDay: Bool) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || value.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            return (formatter.date(from: value), true)
        }
        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = params["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current
        }
        return (formatter.date(from: value), false)
    }

    static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// Video call links: the first https link in the text that looks like a meeting.
    public static func meetingLink(in text: String) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "whereby.com", "webex.com", "meet.jit.si", "facetime.apple.com"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap(\.url).first { url in
            url.scheme == "https" && hosts.contains { url.host()?.lowercased().hasSuffix($0) == true }
        }
    }
}
