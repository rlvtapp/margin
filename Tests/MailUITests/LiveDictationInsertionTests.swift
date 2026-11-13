#if os(macOS)
import AppKit
import Testing
@testable import MailUI

@MainActor @Suite struct LiveDictationInsertionTests {
    private func setup(_ value: String, selection: NSRange) -> (NSWindow, NSTextView, LiveDictationInsertion) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: window.contentView!.bounds)
        editor.allowsUndo = true
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        editor.string = value
        editor.setSelectedRange(selection)
        return (window, editor, LiveDictationInsertion(editor: editor))
    }

    @Test func partialWordsAppearAndAreRevisedInPlace() {
        let (window, editor, insertion) = setup("Hello !", selection: NSRange(location: 6, length: 0))
        defer { window.close() }
        #expect(insertion.update("world"))
        #expect(editor.string == "Hello world!")
        #expect(insertion.update("wonderful world"))
        #expect(editor.string == "Hello wonderful world!")
        insertion.commit("wonderful world")
        insertion.cancel()
        #expect(editor.string == "Hello wonderful world!")
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(editor.string == "Hello !")
    }

    @Test func escapeRestoresSelectedTextIncludingEmoji() {
        let (window, editor, insertion) = setup("Hi 🌍!", selection: NSRange(location: 3, length: 2))
        defer { window.close() }
        #expect(insertion.update("everyone 👋"))
        #expect(editor.string == "Hi everyone 👋!")
        #expect(insertion.update("world"))
        insertion.cancel()
        #expect(editor.string == "Hi 🌍!")
        #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
        #expect(editor.undoManager?.canUndo != true)
    }

    @Test func aLateSpeechResultCannotOverwriteTyping() {
        let (window, editor, insertion) = setup("", selection: NSRange(location: 0, length: 0))
        defer { window.close() }
        #expect(insertion.update("hello"))
        editor.insertText("!", replacementRange: editor.selectedRange())
        #expect(!insertion.update("hello there"))
        insertion.cancel()
        #expect(editor.string == "hello!")
    }

    @Test func movingTheCursorStopsInterimReplacement() {
        let (window, editor, insertion) = setup("", selection: NSRange(location: 0, length: 0))
        defer { window.close() }
        #expect(insertion.update("hello"))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!insertion.update("hello there"))
        insertion.commit("hello there")
        #expect(editor.string == "hello")
    }
}
#endif
