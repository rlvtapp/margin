import Foundation
import Testing
@testable import MailCore

@Suite struct InlinePictureTests {
    let picture = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])

    @Test func picturesTravelInsideTheMessage() {
        var draft = Draft(from: EmailAddress(address: "alex@example.com"), to: [EmailAddress(address: "maya@example.com")], subject: "Plan", text: "Plan\n\n[Picture]")
        draft.html = "<p>Plan</p><p><img src=\"cid:p1@margin\" width=\"600\" alt=\"\"></p>"
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
}
