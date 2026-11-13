import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct ForwardFormattingTests {
    let original = MailMessage(id: "1", mailboxID: "INBOX", from: EmailAddress(name: "Noor", address: "noor@post.example"),
                               to: [EmailAddress(address: "me@home.example")], subject: "Tickets", date: Date())
    let html = """
    <!doctype html><html><head><title>x</title><style>.big{font-size:20px}</style><script>alert(1)</script></head>
    <body><table><tr><td class="big" style="color:#c00">Seat 14A</td></tr></table><img src="cid:logo@x"></body></html>
    """

    @Test func theOriginalKeepsItsFormattingButNotItsHeadOrScripts() {
        let embedded = ForwardedOriginal.embeddable(html)
        #expect(embedded.hasPrefix("<style>.big{font-size:20px}</style>"))
        #expect(embedded.contains("<td class=\"big\" style=\"color:#c00\">Seat 14A</td>"))
        #expect(!embedded.contains("<title>") && !embedded.contains("<script") && !embedded.contains("cid:"))
        #expect(!embedded.lowercased().contains("<body") && !embedded.lowercased().contains("<html"))
    }

    @Test func itGoesOutUnderWhatWasWrittenAndEditAsTextQuotesIt() throws {
        let forwarded = ForwardedOriginal(message: original, body: MessageBody(text: "Seat 14A", html: html))
        var draft = Draft(from: EmailAddress(address: "me@home.example"), to: [EmailAddress(address: "sam@x.example")], subject: "Fwd: Tickets", text: "See below")
        let sent = forwarded.appended(to: draft)
        let sentHTML = try #require(sent.html)
        #expect(sentHTML.hasPrefix("<div>See below</div>"))
        #expect(sentHTML.contains("Forwarded message") && sentHTML.contains("color:#c00"))
        #expect(sent.text.hasPrefix("See below") && sent.text.contains("> Seat 14A"))

        // Edit as Text puts it in the message as quoted text and drops the formatted copy.
        draft.html = nil
        let me = EmailAddress(address: "me@home.example")
        let account = MailAccount(label: "Home", address: me,
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: me.address))
        var state = ComposeState(account: account, draft: draft)
        state.forwarded = forwarded
        state.to = "sam@x.example"
        #expect(try state.validated().html?.contains("color:#c00") == true)
        state.forwardAsText()
        #expect(state.forwarded == nil)
        #expect(state.draft.text.contains("Forwarded message") && state.draft.text.contains("> Seat 14A"))
        #expect(try state.validated().html == nil)
    }
}
