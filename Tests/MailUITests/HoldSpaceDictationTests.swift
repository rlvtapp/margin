#if os(macOS)
import AppKit
import Testing
@testable import MailUI

@MainActor @Suite struct HoldSpaceDictationTests {
    private func event(_ type: NSEvent.EventType, key: UInt16, window: NSWindow,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: " ",
                         charactersIgnoringModifiers: " ", isARepeat: false, keyCode: key)!
    }

    @Test func quickSpacePreservesTypingAndSelection() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentView!.bounds)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        text.string = "helloworld"
        text.setSelectedRange(NSRange(location: 5, length: 0))
        let dictation = HoldSpaceDictation()
        dictation.isEnabled = true
        #expect(dictation.handle(event(.keyDown, key: 49, window: window)))
        #expect(dictation.handle(event(.keyUp, key: 49, window: window)))
        #expect(text.string == "hello world")
    }

    @Test func escapeCancelsWithoutInsertingASpace() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentView!.bounds)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        text.string = "hello"
        let dictation = HoldSpaceDictation()
        dictation.isEnabled = true
        #expect(dictation.handle(event(.keyDown, key: 49, window: window)))
        #expect(dictation.handle(event(.keyDown, key: 53, window: window)))
        #expect(text.string == "hello")
        #expect(!dictation.handle(event(.keyUp, key: 49, window: window)))
    }

    @Test func leavesModifiedSpaceAndNonEditorsAlone() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let dictation = HoldSpaceDictation()
        dictation.isEnabled = true
        #expect(!dictation.handle(event(.keyDown, key: 49, window: window)))
        #expect(!dictation.handle(event(.keyDown, key: 49, window: window, modifiers: .command)))
    }

    @Test func offUntilTurnedOnInExperimental() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentView!.bounds)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        #expect(!HoldSpaceDictation().handle(event(.keyDown, key: 49, window: window)))
        #expect(!MailModel(environment: .preview()).holdSpaceDictates)
    }
}
#endif
