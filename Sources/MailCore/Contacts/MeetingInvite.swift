import Foundation

extension MeetingRequest {
    /// An iTIP REQUEST (RFC 5546) inviting the attendees and booking the rooms, for sending by mail.
    public func iCalendar(now: Date = Date()) -> String {
        let place = rooms.isEmpty ? location : rooms.map(\.name).joined(separator: ", ")
        var lines = [
            "BEGIN:VCALENDAR", "PRODID:-//Margin//Mail//EN", "VERSION:2.0", "METHOD:REQUEST",
            "BEGIN:VEVENT", "UID:\(uid)", "DTSTAMP:\(CalendarInvite.utcStamp(now))", "SEQUENCE:0",
            "DTSTART:\(CalendarInvite.utcStamp(start))", "DTEND:\(CalendarInvite.utcStamp(end))",
            "SUMMARY:\(CalendarInvite.escape(title))",
        ]
        if !notes.isEmpty { lines.append("DESCRIPTION:\(CalendarInvite.escape(notes))") }
        if let place, !place.isEmpty { lines.append("LOCATION:\(CalendarInvite.escape(place))") }
        lines.append("ORGANIZER\(Self.commonName(organizer.name)):mailto:\(organizer.address)")
        for person in attendees {
            lines.append("ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE\(Self.commonName(person.name)):mailto:\(person.address)")
        }
        for room in rooms {
            lines.append("ATTENDEE;CUTYPE=ROOM;ROLE=NON-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE\(Self.commonName(room.name)):mailto:\(room.email)")
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(Self.fold).joined(separator: "\r\n") + "\r\n"
    }

    static func commonName(_ name: String?) -> String {
        name.map { ";CN=\(CalendarInvite.paramValue($0))" } ?? ""
    }

    /// Splits a content line so no piece is longer than 75 octets, continuing with a space
    /// (RFC 5545 §3.1). Characters are never cut in half.
    static func fold(_ line: String) -> String {
        var pieces: [String] = []
        var current = ""
        var octets = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = pieces.isEmpty ? 75 : 74
            if octets + size > limit {
                pieces.append(current)
                current = ""
                octets = 0
            }
            current.append(character)
            octets += size
        }
        pieces.append(current)
        return pieces.joined(separator: "\r\n ")
    }
}
