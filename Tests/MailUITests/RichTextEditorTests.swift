#if canImport(AppKit)
import AppKit
import Testing
@testable import MailUI

/// The message editor and the system's inline predictions (the grey rest of a word).
@MainActor @Suite struct RichTextEditorTests {
    @Test func textFromOutsideWaitsWhileAPredictionShows() {
        let view = NSTextView()
        view.string = "See you tomo"
        view.setSelectedRange(NSRange(location: 12, length: 0))
        // The prediction is marked text in the view, not yet in the draft.
        view.setMarkedText("rrow", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(!RichTextEditor.takesText("See you tomo", into: view))

        // Once it's taken or dismissed, text set from outside goes in as before.
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(RichTextEditor.takesText("See you tomorrow, Sam", into: view))
        #expect(!RichTextEditor.takesText(view.string, into: view))
    }
}
#endif
