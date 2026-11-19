import Foundation
import Testing
@testable import MailCore

@Suite struct AppLinksTests {
    @Test func readsComposeAndInviteLinks() {
        let compose = MarginLink(URL(string: "margin://compose?to=maya@example.com,not-an-address&subject=Planning%20notes")!)
        #expect(compose == .compose(to: ["maya@example.com"], cc: [], subject: "Planning notes", body: nil))
        #expect(compose?.mailto?.absoluteString == "mailto:maya@example.com?subject=Planning%20notes")
        #expect(MarginLink(URL(string: "margin://invite?uid=m-1")!) == .invite(uid: "m-1"))
        #expect(MarginLink(URL(string: "margin://invite")!) == nil)
        #expect(MarginLink(URL(string: "margin://message/123")!) == nil)
    }
}
