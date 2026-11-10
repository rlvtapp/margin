import Foundation
import Testing
@testable import MailCore

@Suite struct AutoReplyTests {
    let start = ISO8601DateFormatter().date(from: "2026-12-20T00:00:00Z")!
    let end = ISO8601DateFormatter().date(from: "2027-01-04T00:00:00Z")!

    @Test func microsoftScheduledReply() async throws {
        let api = GraphFakeAPI()
        api.on("mailboxSettings", #"{}"#)
        try await MicrosoftAutoReply(accessToken: "t", send: api.send)
            .setAutoReply(AutoReply(isOn: true, start: start, end: end, message: "Back on the 4th.\nAlex", answersOutside: false))
        let body = try #require(api.json(of: "mailboxSettings")?["automaticRepliesSetting"] as? [String: Any])
        #expect(body["status"] as? String == "scheduled")
        #expect(body["externalAudience"] as? String == "none")
        #expect((body["internalReplyMessage"] as? String)?.contains("Back on the 4th.<br>Alex") == true)
        #expect(api.requests.first?.httpMethod == "PATCH")
    }

    @Test func microsoftReadsTheReply() async throws {
        let api = GraphFakeAPI()
        api.on("mailboxSettings", #"{"automaticRepliesSetting": {"status": "alwaysEnabled", "externalAudience": "all", "internalReplyMessage": "<p>Away</p>"}}"#)
        let reply = try await MicrosoftAutoReply(accessToken: "t", send: api.send).autoReply()
        #expect(reply.isOn && reply.start == nil && reply.answersOutside)
        #expect(reply.message.contains("Away"))
    }

    @Test func gmailVacationResponder() async throws {
        let api = GraphFakeAPI()
        api.on("settings/vacation", #"{}"#)
        try await GmailAutoReply(accessToken: "t", send: api.send)
            .setAutoReply(AutoReply(isOn: true, start: start, end: end, subject: "Away", message: "Back soon"))
        let body = try #require(api.json(of: "settings/vacation"))
        #expect(body["enableAutoReply"] as? Bool == true)
        #expect(body["startTime"] as? String == String(Int64(start.timeIntervalSince1970 * 1000)))
        #expect(body["responseSubject"] as? String == "Away")
        #expect(api.requests.first?.httpMethod == "PUT")
    }
}
