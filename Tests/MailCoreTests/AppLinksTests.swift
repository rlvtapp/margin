import Foundation
import Testing
@testable import MailCore

@Suite struct AppLinksTests {
    func items(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func eventLinkCarriesTheUIDStartAndInvitation() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let url = DaybookLink.event(uid: "abc+1@example.com", start: start, ics: "BEGIN:VCALENDAR")
        #expect(url.scheme == "daybook" && url.host == "event")
        let query = items(url)
        #expect(query["uid"] == "abc+1@example.com")
        #expect(query["start"] == "2027-01-15T08:00:00Z")
        let ics = try #require(query["ics"])
        #expect(!ics.contains("=") && !ics.contains("+") && !ics.contains("/"))
        let padded = ics.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - ics.count % 4) % 4)
        #expect(String(data: try #require(Data(base64Encoded: padded)), encoding: .utf8) == "BEGIN:VCALENDAR")
    }

    @Test func newLinkFillsTheMeeting() {
        let url = DaybookLink.new(title: "Planning & review", start: Date(timeIntervalSince1970: 0), end: nil,
                                  attendees: ["maya@example.com", "noor@example.com"], location: "", notes: nil)
        let query = items(url)
        #expect(url.host == "new")
        #expect(query["title"] == "Planning & review")
        #expect(query["attendees"] == "maya@example.com,noor@example.com")
        #expect(query["location"] == nil)
    }

    @Test func readsComposeAndInviteLinks() {
        let compose = MarginLink(URL(string: "margin://compose?to=maya@example.com,not-an-address&subject=Planning%20notes")!)
        #expect(compose == .compose(to: ["maya@example.com"], cc: [], subject: "Planning notes", body: nil))
        #expect(compose?.mailto?.absoluteString == "mailto:maya@example.com?subject=Planning%20notes")
        #expect(MarginLink(URL(string: "margin://invite?uid=m-1")!) == .invite(uid: "m-1"))
        #expect(MarginLink(URL(string: "margin://invite")!) == nil)
        #expect(MarginLink(URL(string: "margin://message/123")!) == nil)
    }
}
