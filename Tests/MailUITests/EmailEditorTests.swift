#if canImport(AppKit)
import AppKit
import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct EmailEditorTests {
    private func editor(_ text: String) -> (NSTextView, RichTextController) {
        let view = NSTextView()
        view.string = text
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        view.textStorage?.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: (text as NSString).length))
        let controller = RichTextController()
        controller.textView = view
        return (view, controller)
    }

    @Test func theHTMLCarriesEveryStyleOnTheElementItself() throws {
        let (view, controller) = editor("Hello bold world\nIndented and spaced\nLinked Margin")
        view.setSelectedRange(NSRange(location: 6, length: 4))
        controller.toggle(.boldFontMask)
        view.setSelectedRange(NSRange(location: 11, length: 5))
        controller.setColor(FormattingBar.colors.first { $0.name == "Red" }!.value)
        view.setSelectedRange(NSRange(location: 18, length: 3))
        controller.indent(1)
        controller.setLineSpacing(1.5)
        controller.setFont("Georgia")
        let storage = try #require(view.textStorage)
        storage.addAttribute(.link, value: URL(string: "https://margin.relevate.app")!, range: NSRange(location: 44, length: 6))

        let html = try #require(RichTextController.html(from: storage))
        #expect(!html.contains("<style") && !html.contains("class="))
        #expect(html.contains("Hello <b>bold</b> <span style=\"color:#cc2626\">world</span>"))
        #expect(html.contains("<div style=\"margin:0;margin-left:28px;line-height:1.5\">"))
        #expect(html.contains("font-family:'Georgia', serif"))
        #expect(html.contains("<a href=\"https://margin.relevate.app\">Margin</a>"))
        #expect(RichTextController.isFormatted(storage))
    }

    @Test func picturesGoOutAsInlinePartsAndPlainTextLeavesTheirPlaceholderOut() throws {
        let (view, controller) = editor("See the plan:\n")
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 900, height: 300))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 900, height: 300).fill(); image.unlockFocus()
        let url = folder.appending(path: "plan.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        view.setSelectedRange(NSRange(location: 14, length: 0))
        controller.insertPictures([url])

        let written = EmailHTMLWriter.write(try #require(view.textStorage))
        let picture = try #require(written.images.first)
        #expect(written.images.count == 1 && picture.contentID?.hasSuffix(EmailHTMLWriter.inlineSuffix) == true)
        #expect(written.html.contains("src=\"cid:\(picture.contentID!)\" width=\"480\""))
        // Written again, the same picture keeps its name, so the draft doesn't gain copies.
        #expect(EmailHTMLWriter.write(view.textStorage!).images.map(\.contentID) == written.images.map(\.contentID))

        var draft = Draft(from: EmailAddress(address: "kaan@studio.example"), to: [EmailAddress(address: "jp@studio.example")],
                          subject: "Plan", text: view.string)
        draft.html = written.html
        draft.attachments = written.images
        let message = String(decoding: MessageBuilder.build(draft, boundary: "b"), as: UTF8.self)
        #expect(message.contains("multipart/related") && message.contains("Content-ID: <\(picture.contentID!)>"))
        #expect(!message.contains("\u{FFFC}"))
    }

    @Test func clearFormattingKeepsLinksAndPlainMailStaysPlain() throws {
        let (view, controller) = editor("Plain words and a link")
        let storage = try #require(view.textStorage)
        #expect(!RichTextController.isFormatted(storage))
        storage.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 18, length: 4))
        view.setSelectedRange(NSRange(location: 0, length: 22))
        controller.toggle(.boldFontMask)
        controller.setHighlight(FormattingBar.highlights[0].value)
        controller.clearFormatting()
        let html = try #require(RichTextController.html(from: storage))
        #expect(!html.contains("<b>") && !html.contains("background-color"))
        #expect(html.contains("<a href=\"https://example.com\">link</a>"))
        // Indents step back to nothing, never below.
        controller.indent(-1)
        #expect(EmailHTMLWriter.paragraphCSS(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) == "margin:0")
    }

    @Test func theColoursAreRelevatesNamedSet() {
        #expect(FormattingBar.colors.map(\.name) == ["Gray", "Brown", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Red"])
        #expect(FormattingBar.highlights.count == 9)
    }
}
#endif
