import Foundation
import Testing
@testable import MailCore

/// Invitations name their time zone in several ways; each must land on the same hour Apple
/// Calendar shows, whatever zone this Mac is in.
@Suite struct InviteTimeZoneTests {
    static func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    static func invite(tzid: String, start: String, end: String, timezone: String = "") -> String {
        """
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        PRODID:Microsoft Exchange Server 2010\r
        \(timezone)BEGIN:VEVENT\r
        UID:tz-test@example.com\r
        SUMMARY:Planning\r
        DTSTART;TZID=\(tzid):\(start)\r
        DTEND;TZID=\(tzid):\(end)\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
    }

    @Test func everyWindowsNameIsAKnownZone() {
        for (windows, iana) in CalendarTimeZones.windows {
            #expect(TimeZone(identifier: iana) != nil, "\(windows) → \(iana)")
        }
    }

    @Test func readsWindowsZoneNames() throws {
        let winter = try #require(CalendarInvite.parse(Self.invite(tzid: "W. Europe Standard Time",
                                                                    start: "20261125T100000", end: "20261125T110000")))
        #expect(winter.start == Self.utc("2026-11-25T09:00:00Z"))
        #expect(winter.end == Self.utc("2026-11-25T10:00:00Z"))

        let summer = try #require(CalendarInvite.parse(Self.invite(tzid: "Pacific Standard Time",
                                                                    start: "20260715T100000", end: "20260715T103000")))
        #expect(summer.start == Self.utc("2026-07-15T17:00:00Z"))

        let quoted = try #require(CalendarInvite.parse(Self.invite(tzid: "\"India Standard Time\"",
                                                                    start: "20261125T100000", end: "20261125T110000")))
        #expect(quoted.start == Self.utc("2026-11-25T04:30:00Z"))
    }

    @Test func readsPrefixedIANANames() throws {
        let invite = try #require(CalendarInvite.parse(Self.invite(tzid: "/mozilla.org/20070129_1/Europe/Berlin",
                                                                    start: "20260715T100000", end: "20260715T110000")))
        #expect(invite.start == Self.utc("2026-07-15T08:00:00Z"))
    }

    /// Outlook's display name means nothing on its own; the invite's VTIMEZONE says what it is.
    @Test func fallsBackToTheInvitesOwnRules() throws {
        let name = "(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna"
        let timezone = """
        BEGIN:VTIMEZONE\r
        TZID:\(name)\r
        BEGIN:STANDARD\r
        DTSTART:16010101T030000\r
        TZOFFSETFROM:+0200\r
        TZOFFSETTO:+0100\r
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10\r
        END:STANDARD\r
        BEGIN:DAYLIGHT\r
        DTSTART:16010101T020000\r
        TZOFFSETFROM:+0100\r
        TZOFFSETTO:+0200\r
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3\r
        END:DAYLIGHT\r
        END:VTIMEZONE\r

        """
        let summer = try #require(CalendarInvite.parse(Self.invite(tzid: "\"\(name)\"", start: "20260715T100000",
                                                                    end: "20260715T110000", timezone: timezone)))
        #expect(summer.start == Self.utc("2026-07-15T08:00:00Z"))
        #expect(summer.end == Self.utc("2026-07-15T09:00:00Z"))

        let winter = try #require(CalendarInvite.parse(Self.invite(tzid: "\"\(name)\"", start: "20261125T100000",
                                                                    end: "20261125T110000", timezone: timezone)))
        #expect(winter.start == Self.utc("2026-11-25T09:00:00Z"))

        // The day after the change to summer time (last Sunday of March 2026 is the 29th).
        let afterChange = try #require(CalendarInvite.parse(Self.invite(tzid: "\"\(name)\"", start: "20260330T100000",
                                                                         end: "20260330T110000", timezone: timezone)))
        #expect(afterChange.start == Self.utc("2026-03-30T08:00:00Z"))
        let beforeChange = try #require(CalendarInvite.parse(Self.invite(tzid: "\"\(name)\"", start: "20260328T100000",
                                                                          end: "20260328T110000", timezone: timezone)))
        #expect(beforeChange.start == Self.utc("2026-03-28T09:00:00Z"))
    }

    /// Older calendars write "second Sunday of March" as a Sunday between the 8th and the 14th.
    @Test func readsMonthDayStyleRules() throws {
        let timezone = """
        BEGIN:VTIMEZONE\r
        TZID:Our Office\r
        BEGIN:DAYLIGHT\r
        DTSTART:20070311T020000\r
        TZOFFSETFROM:-0500\r
        TZOFFSETTO:-0400\r
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=SU;BYMONTHDAY=8,9,10,11,12,13,14\r
        END:DAYLIGHT\r
        BEGIN:STANDARD\r
        DTSTART:20071104T020000\r
        TZOFFSETFROM:-0400\r
        TZOFFSETTO:-0500\r
        RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=SU;BYMONTHDAY=1,2,3,4,5,6,7\r
        END:STANDARD\r
        END:VTIMEZONE\r

        """
        let march = try #require(CalendarInvite.parse(Self.invite(tzid: "Our Office", start: "20260320T100000",
                                                                   end: "20260320T110000", timezone: timezone)))
        #expect(march.start == Self.utc("2026-03-20T14:00:00Z"))
        let december = try #require(CalendarInvite.parse(Self.invite(tzid: "Our Office", start: "20261210T100000",
                                                                      end: "20261210T110000", timezone: timezone)))
        #expect(december.start == Self.utc("2026-12-10T15:00:00Z"))
    }

    @Test func readsOffsets() {
        #expect(ZoneRules.offset("+0100") == 3600)
        #expect(ZoneRules.offset("-0530") == -19_800)
        #expect(ZoneRules.offset("+013000") == 5400)
        #expect(ZoneRules.offset("0100") == nil)
    }

    @Test func graphDatesInWindowsZones() {
        let date = MicrosoftGraphClient.parseGraphDate(GraphDateTime(dateTime: "2026-11-25T10:00:00.0000000",
                                                                     timeZone: "W. Europe Standard Time"))
        #expect(date == Self.utc("2026-11-25T09:00:00Z"))
    }
}
