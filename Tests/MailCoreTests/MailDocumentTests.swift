import Foundation
import Testing
@testable import MailCore

@Suite struct MailDocumentTests {
    static let typed = """
    ## Plan for Thursday
    A few things before we meet:

    - Draft the **agenda**
    - Book a room
    - [ ] Send the deck
    - [x] Invite Noor

    1. Budget
    2. Timeline

    > Keep it under an hour.

    ---
    See https://example.com/plan or [the doc](https://example.com/doc).
    """

    @Test func readsTypedStructure() {
        let document = MailDocument.parse(Self.typed)
        #expect(document.blocks.count == 8)
        #expect(document.blocks[0] == .heading(level: 2, [.init("Plan for Thursday")]))
        guard case .bullets(let bullets) = document.blocks[2] else { Issue.record("no bullets"); return }
        #expect(bullets[0] == [.init("Draft the "), .init("agenda", bold: true)])
        guard case .tasks(let tasks) = document.blocks[3] else { Issue.record("no tasks"); return }
        #expect(tasks.map(\.done) == [false, true])
        guard case .numbered(let steps) = document.blocks[4] else { Issue.record("no numbered list"); return }
        #expect(steps.count == 2)
        #expect(document.blocks[6] == .divider)
        guard case .paragraph(let last) = document.blocks[7] else { Issue.record("no paragraph"); return }
        #expect(last.compactMap(\.link).map(\.absoluteString) == ["https://example.com/plan", "https://example.com/doc"])
        #expect(document.hasStructure)
    }

    @Test func plainWritingStaysPlain() {
        let document = MailDocument.parse("Hi Maya,\n\nThanks for this. See you at 3pm - looking forward.\n\nAlex")
        #expect(!document.hasStructure)
        #expect(document.blocks.count == 3)
    }

    @Test func emailHTMLUsesOnlyInlineStylesAndCommonTags() {
        let html = MailDocument.parse(Self.typed + "\n\n```\nlet x = 1 < 2\n```\n\n| Day | Room |\n|---|---|\n| Thu | 3 |").html()
        #expect(!html.contains("class="))
        #expect(!html.contains("<style"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<h1"))
        #expect(html.contains("<h3 style="))
        #expect(html.contains("<ul style="))
        #expect(html.contains("☐ Send the deck"))
        #expect(html.contains("text-decoration:line-through\">Invite Noor"))
        #expect(html.contains("<blockquote style="))
        #expect(html.contains("let x = 1 &lt; 2"))
        #expect(html.contains("<th style="))
        #expect(html.contains("<a href=\"https://example.com/doc\""))
    }

    @Test func plainTextKeepsTheStructure() {
        let text = MailDocument.parse(Self.typed).plainText()
        #expect(text.hasPrefix("## Plan for Thursday"))
        #expect(text.contains("- Draft the agenda"))
        #expect(text.contains("[ ] Send the deck\n[x] Invite Noor"))
        #expect(text.contains("1. Budget\n2. Timeline"))
        #expect(text.contains("> Keep it under an hour."))
        #expect(text.contains("the doc (https://example.com/doc)"))
    }

    @Test func escapesWhatWasTyped() {
        let html = MailDocument.parse("## <script>alert(1)</script> & co").html()
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; co"))
    }
}

@Suite struct InlinePictureTests {
    let picture = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])

    @Test func picturesTravelInsideTheMessage() {
        var draft = Draft(from: EmailAddress(address: "alex@example.com"), to: [EmailAddress(address: "maya@example.com")], subject: "Plan", text: "Plan\n\n[Picture]")
        draft.html = MailDocument(blocks: [.paragraph([.init("Plan")]), .image(contentID: "p1@margin", alt: "", width: 1200)]).html()
        draft.attachments = [OutgoingAttachment(filename: "picture-1.png", mimeType: "image/png", data: picture, contentID: "p1@margin"),
                             OutgoingAttachment(filename: "notes.pdf", mimeType: "application/pdf", data: Data("pdf".utf8))]
        let message = String(decoding: MessageBuilder.build(draft, boundary: "b"), as: UTF8.self)
        #expect(message.contains("multipart/mixed"))
        #expect(message.contains("multipart/related"))
        #expect(message.contains("Content-ID: <p1@margin>"))
        #expect(message.contains("Content-Disposition: inline; filename=\"picture-1.png\""))
        #expect(message.contains("Content-Disposition: attachment; filename=\"notes.pdf\""))
        #expect(draft.html?.contains("src=\"cid:p1@margin\"") == true)
        #expect(draft.html?.contains("width=\"600\"") == true)

        // Read back, the picture is in place and not listed as an attachment.
        let body = MIMEMessage.parse(MessageBuilder.build(draft, boundary: "b")).body
        #expect(body.html?.contains("data:image/png;base64,") == true)
        #expect(body.html?.contains("cid:") == false)
        #expect(body.attachments.map(\.filename) == ["notes.pdf"])
    }

    @Test func picturesTheHTMLDoesntShowStayAttachments() {
        let body = MessageBody(text: "Hi", html: "<p>Hi</p>",
                               attachments: [AttachmentInfo(filename: "photo.jpg", mimeType: "image/jpeg", data: Data([1]), contentID: "x@y")])
        #expect(body.embeddingInlineImages().attachments.count == 1)
    }

    @Test func plainTextNamesThePicture() {
        #expect(MailDocument(blocks: [.image(contentID: "a", alt: "Floor plan", width: nil)]).plainText() == "[Picture: Floor plan]")
    }
}
