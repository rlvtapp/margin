import Foundation
import Testing
@testable import MailCore

@Suite struct StreamedAnswerTests {
    /// The answer text is read out of JSON that's still arriving, escapes and all.
    @Test func readsTheAnswerSoFar() {
        #expect(StreamedAnswer.answerSoFar(in: "{\"ans") == nil)
        #expect(StreamedAnswer.answerSoFar(in: "{\"answer\": ") == nil)
        #expect(StreamedAnswer.answerSoFar(in: "{\"answer\": \"") == "")
        #expect(StreamedAnswer.answerSoFar(in: "{\"answer\": \"Lunch with Noor") == "Lunch with Noor")
        #expect(StreamedAnswer.answerSoFar(in: "{\"answer\":\"Line one\\nLine \\\"two\\\"") == "Line one\nLine \"two\"")
        #expect(StreamedAnswer.answerSoFar(in: "{\"answer\":\"Caf\\u00e9 at 10\\") == "Café at 10")
        #expect(StreamedAnswer.answerSoFar(in: "{\"answer\":\"Caf\\u00") == "Caf")
        #expect(StreamedAnswer.answerSoFar(in: "{\"answer\":\"Done.\",\"sources\":[1]}") == "Done.")
    }

    /// Each time the text grows it's handed on once, and the whole JSON is kept for the end.
    @Test func handsOnGrowingText() async {
        actor Seen { var all: [String] = []; func add(_ text: String) { all.append(text) } }
        let seen = Seen()
        var reader = StreamedAnswer { await seen.add($0) }
        for piece in ["{\"answ", "er\":\"Hi", " there", "\",\"sources\":", "[2]}"] { await reader.add(piece) }
        #expect(await seen.all == ["Hi", "Hi there"])
        #expect(reader.text == "{\"answer\":\"Hi there\",\"sources\":[2]}")
    }
}

@Suite struct SignInHiccupTests {
    /// Outlook.com's "not ready yet" answers are retried; a wrong password isn't.
    @Test func recognisesPassingAnswers() {
        #expect(IMAPProvider.isPassing("User is authenticated but not connected."))
        #expect(IMAPProvider.isPassing("Service temporarily unavailable"))
        #expect(!IMAPProvider.isPassing("AUTHENTICATE failed."))
        #expect(!IMAPProvider.isPassing("Invalid credentials"))
    }
}

@Suite struct IdentityTokenTests {
    /// Which account said yes, read from the identity token that comes with the sign-in.
    @Test func readsTheAddressThatSignedIn() {
        func token(_ claims: String) -> String {
            let body = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "e30.\(body).sig"
        }
        #expect(OAuthClient.address(inIdentityToken: token(#"{"email":"Kaan@Relevate.app"}"#)) == "kaan@relevate.app")
        #expect(OAuthClient.address(inIdentityToken: token(#"{"preferred_username":"kaanmol@outlook.com"}"#)) == "kaanmol@outlook.com")
        #expect(OAuthClient.address(inIdentityToken: token(#"{"name":"Kaan"}"#)) == nil)
        #expect(OAuthClient.address(inIdentityToken: "not-a-token") == nil)
        #expect(OAuthClient.name(inIdentityToken: token(#"{"name":"Kaan Mollaoglu"}"#)) == "Kaan Mollaoglu")
        #expect(OAuthClient.name(inIdentityToken: token(#"{"name":"kaan@relevate.app"}"#)) == nil)
    }
}

@Suite struct DiscussionListTests {
    /// A group people write to isn't one subscription; a newsletter keeps its list's own name.
    @Test func groupsArentSubscriptions() {
        func message(_ id: String, from: String, list: String) -> MailMessage {
            MailMessage(id: id, mailboxID: "INBOX", messageID: "\(id)@x", from: EmailAddress(name: from, address: "\(from)@example.com"),
                        to: [], subject: "S\(id)", date: Date(timeIntervalSince1970: Double(id)!), listHeaders: ["list-id": list])
        }
        let group = ["1", "2", "3"].enumerated().map { index, id in
            message(id, from: ["noor", "sam", "maya"][index], list: "Club <club.example.com>")
        }
        let weekly = ["4", "5"].map { message($0, from: "news", list: "\"Weekly\" <weekly.example.com>") }
        let senders = NewsletterReport.senders(from: (group + weekly).map { MailThread(id: $0.id, messages: [$0]) })
        #expect(senders.map(\.id) == ["weekly.example.com"])
        #expect(senders.first?.name == "Weekly")
    }
}
