#if canImport(AppKit)
import AppKit
import Testing
@testable import MailUI

@MainActor @Suite struct FormattingBarTests {
    func text(_ attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: "Hello", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor].merging(attributes) { $1 })
    }

    @Test func plainTextStaysPlainAndEachFormatCounts() {
        #expect(!RichTextController.isFormatted(text([:])))
        let red = NSColor(srgbRed: 0.8, green: 0.15, blue: 0.15, alpha: 1)
        #expect(RichTextController.isFormatted(text([.foregroundColor: red])))
        #expect(RichTextController.isFormatted(text([.backgroundColor: NSColor.yellow])))
        #expect(RichTextController.isFormatted(text([.strikethroughStyle: NSUnderlineStyle.single.rawValue])))
        #expect(RichTextController.isFormatted(text([.font: NSFont.systemFont(ofSize: 24)])))
        #expect(RichTextController.isFormatted(text([.font: NSFont(name: "Georgia", size: 14)!])))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        #expect(RichTextController.isFormatted(text([.paragraphStyle: centered])))
    }

    @Test func theNormalColourIsLeftOutOfTheEmail() throws {
        let html = try #require(RichTextController.html(from: text([.font: NSFont.boldSystemFont(ofSize: 14)])))
        #expect(!html.contains("color:"))
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let colored = try #require(RichTextController.html(from: text([.foregroundColor: red])))
        #expect(colored.contains("color:#ff0000"))   // written on the element, in sRGB
    }
}
#endif
