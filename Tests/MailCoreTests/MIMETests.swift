import Foundation
import Testing
@testable import MailCore

@Suite struct MIMETests {
    @Test func decodesEncodedWords() {
        #expect(MIMEWords.decode("=?UTF-8?B?w4l0w6k=?=") == "Été")
        #expect(MIMEWords.decode("=?ISO-8859-1?Q?Caf=E9_cr=E8me?=") == "Café crème")
        // Whitespace between encoded words disappears; around plain text it stays.
        #expect(MIMEWords.decode("=?UTF-8?Q?a?= =?UTF-8?Q?b?= and c") == "ab and c")
        #expect(MIMEWords.decode("Plain subject") == "Plain subject")
    }

    @Test func roundTripsQuotedPrintable() {
        let text = "Grüße aus Köln = 100% " + String(repeating: "long line ", count: 12)
        let encoded = QuotedPrintable.encode(text)
        #expect(encoded.split(separator: "\r\n").allSatisfy { $0.count <= 76 })
        #expect(String(decoding: QuotedPrintable.decode(encoded), as: UTF8.self) == text)
    }

    @Test func readsMultipartAlternativeAndAttachments() {
        let latin1Body = "Caf\u{E9}".data(using: .isoLatin1)!
        var raw = Array("""
        From: Maya <maya@studio.example>\r
        Subject: =?UTF-8?Q?Pl=C3=A4ne?=\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        preamble\r
        --outer\r
        Content-Type: multipart/alternative; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/plain; charset=iso-8859-1\r
        Content-Transfer-Encoding: 8bit\r
        \r

        """.utf8)
        raw += Array(latin1Body)
        raw += Array("""
        \r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(Data("<p>Caf&eacute;</p>".utf8).base64EncodedString())\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="plan.pdf"\r
        Content-Disposition: attachment; filename*=utf-8''pl%C3%A4n.pdf\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0=\r
        --outer--\r

        """.utf8)
        let message = MIMEMessage.parse(raw)
        #expect(message.text == "Café")
        #expect(message.html == "<p>Caf&eacute;</p>")
        #expect(message.attachments == [AttachmentInfo(filename: "plän.pdf", mimeType: "application/pdf", data: Data("%PDF-".utf8))])
        #expect(MIMEWords.decode(message.headers["subject"] ?? "") == "Pläne")
    }

    @Test func fallsBackToHTMLText() {
        let raw = Array("Content-Type: text/html\r\n\r\n<style>p{}</style><p>Hello&nbsp;there</p><p>Second</p>".utf8)
        #expect(MIMEMessage.parse(raw).body.text == "Hello there\nSecond")
    }

    @Test func buildsAMessage() {
        let draft = Draft(
            from: EmailAddress(name: "Jürgen", address: "j@example.com"),
            to: [EmailAddress(name: "Maya", address: "maya@studio.example")],
            bcc: [EmailAddress(address: "hidden@example.com")],
            subject: "Über the plan", text: "Line one\n.dot line", inReplyTo: "a1@studio.example", references: ["a1@studio.example"]
        )
        let text = String(decoding: MessageBuilder.build(draft, messageID: "x@example.com"), as: UTF8.self)
        #expect(text.contains("From: =?UTF-8?B?SsO8cmdlbg==?= <j@example.com>\r\n"))
        #expect(text.contains("Subject: =?UTF-8?B?"))
        #expect(text.contains("In-Reply-To: <a1@studio.example>\r\n"))
        #expect(!text.contains("hidden@example.com"))
        let parsed = MIMEMessage.parse(Array(text.utf8))
        #expect(parsed.body.text == "Line one\n.dot line")
        #expect(String(decoding: SMTPClient.dotStuffed(Array(text.utf8)), as: UTF8.self).contains("\r\n..dot line"))
    }

    @Test func parsesAddressLists() {
        #expect(EmailAddress.parseList("Maya <maya@studio.example>, \"Okafor, Sam\" <sam@kettle.example>; jun@fieldwork.example")
            == [EmailAddress(name: "Maya", address: "maya@studio.example"),
                EmailAddress(name: "Okafor, Sam", address: "sam@kettle.example"),
                EmailAddress(address: "jun@fieldwork.example")])
        #expect(EmailAddress.parseList("not an address") == nil)
        #expect(MailDate.parse("Tue, 3 Nov 2026 10:00:00 +0100 (CET)") != nil)
        #expect(MailDate.parse("3 Nov 2026 10:00:00 GMT") != nil)
    }
}
