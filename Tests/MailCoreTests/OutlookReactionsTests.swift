import Foundation
import Testing
@testable import MailCore

@Suite struct OutlookReactionsTests {
    static let when = Date(timeIntervalSince1970: 1_783_000_000)

    @Test func readsTheSummaryLikeTheOpenSourceParsers() throws {
        let entries = [
            OutlookReactions.Entry(emoji: "👍", name: "Jane Jolie", address: "jane@example.org", date: Self.when),
            OutlookReactions.Entry(emoji: "❤", name: "Sam Okafor", address: "sam@example.org", date: Self.when.addingTimeInterval(120), isBcc: true),
        ]
        let read = try #require(OutlookReactions.decodeSummary(OutlookReactions.encodeSummary(entries)))
        #expect(read.map(\.emoji) == ["👍", "❤"])
        #expect(read.map(\.address) == ["jane@example.org", "sam@example.org"])
        #expect(read[1].isBcc && !read[0].isBcc)
        // Kept to the minute.
        #expect(abs(read[0].date.timeIntervalSince(Self.when)) < 60)
    }

    @Test func readsBytesWrittenByHand() throws {
        // "v1", one 😆 counted (the count's high byte is a zero, which mustn't end the counts),
        // then the record: no Bcc, 222,000,000 minutes after 1601, "😆,Jane,jane@example.org,", end.
        var bytes: [UInt8] = [0x76, 0x01] + Array("😆".utf8) + [0x3D, 0x01, 0x00, 0x00]
        let minutes = UInt32(222_000_000)
        bytes += [0x00, UInt8(minutes & 0xFF), UInt8(minutes >> 8 & 0xFF), UInt8(minutes >> 16 & 0xFF), UInt8(minutes >> 24)]
        bytes += Array("😆,Jane,jane@example.org,".utf8) + [0x00]
        let read = try #require(OutlookReactions.decodeSummary(Data(bytes)))
        #expect(read.count == 1)
        #expect(read[0].emoji == "😆" && read[0].name == "Jane" && read[0].address == "jane@example.org")
        let expected = OutlookReactions.epoch.addingTimeInterval(222_000_000 * 60)
        #expect(read[0].date == expected)
    }

    @Test func leavesOutTakenBackReactionsAndStopsAtDamage() {
        let taken = OutlookReactions.Entry(emoji: "0", name: "Jane", address: "jane@example.org", date: Self.when)
        #expect(OutlookReactions.decodeSummary(OutlookReactions.encodeSummary([taken])) == [])
        #expect(OutlookReactions.decodeSummary(Data("not a summary".utf8)) == nil)
        #expect(OutlookReactions.decodeSummary(Data()) == nil)
        // Cut off mid-record: what came before stays.
        let two = OutlookReactions.encodeSummary([
            OutlookReactions.Entry(emoji: "🎉", name: "A", address: "a@example.org", date: Self.when),
            OutlookReactions.Entry(emoji: "😢", name: "B", address: "b@example.org", date: Self.when),
        ])
        let cut = OutlookReactions.decodeSummary(two.prefix(two.count - 12))
        #expect(cut?.map(\.emoji) == ["🎉"])
    }

    @Test func asksGraphForTheMessageByItsMessageID() async throws {
        let summary = OutlookReactions.encodeSummary([
            OutlookReactions.Entry(emoji: "🎉", name: "Jane Jolie", address: "jane@example.org", date: Self.when),
        ]).base64EncodedString()
        let seen = Seen()
        let client = MicrosoftGraphClient(accessToken: "t") { request in
            await seen.add(request.url!.absoluteString)
            let body = """
            {"value":[{"id":"AAMk1","internetMessageId":"<plan+q3@example.com>","singleValueExtendedProperties":[
              {"id":"Binary {41f28f13-83f4-4114-a584-eedb5a6b0bff} Name ReactionsSummary","value":"\(summary)"},
              {"id":"Integer {41f28f13-83f4-4114-a584-eedb5a6b0bff} Name ReactionsCount","value":"1"}]}]}
            """
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let found = try await client.outlookReactions(messageID: "plan+q3@example.com")
        #expect(found.map(\.emoji) == ["🎉"])
        let url = try #require(await seen.urls.first)
        let query = try #require(URLComponents(string: url)?.queryItems)
        #expect(query.first { $0.name == "$filter" }?.value == "internetMessageId eq '<plan+q3@example.com>'")
        #expect(query.first { $0.name == "$expand" }?.value?.contains("name ReactionsSummary") == true)
        // "+" is sent encoded, so Graph doesn't read it as a space.
        #expect(url.contains("plan%2Bq3"))
    }

    @Test func aMissingMessageOrPermissionIsNothingToShow() async throws {
        for status in [403, 404] {
            let client = MicrosoftGraphClient(accessToken: "t") { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            #expect(try await client.outlookReactions(messageID: "x@example.com").isEmpty)
        }
    }

    @Test func isAskedForOnlyWhenTurnedOn() throws {
        let registry = OAuthClientRegistry(googleClientID: nil, microsoftClientID: "client")
        // Sign-in doesn't ask for reading mail.
        let signIn = try #require(registry.client(for: .microsoft))
        #expect(!signIn.scopes.contains("https://graph.microsoft.com/Mail.Read"))
        let turnedOn = try #require(registry.client(for: .microsoft, access: [.reactions]))
        #expect(turnedOn.scopes == ["https://graph.microsoft.com/Mail.Read", "offline_access", "openid", "email"])
        #expect(APIAccess.offered(by: .microsoft).contains(.reactions))
        #expect(!APIAccess.offered(by: .google).contains(.reactions))
    }
}

private actor Seen {
    var urls: [String] = []
    func add(_ url: String) { urls.append(url) }
}
