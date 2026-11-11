#if os(macOS)
import AppKit
import MailCore
import SwiftUI
import Testing
@testable import MailUI

/// The recipient field in a real window, with real key commands sent to its text field.
@MainActor @Suite struct RecipientFieldTests {
    private func field(in view: NSView) -> NSTextField? {
        if let found = view as? NSTextField, found.isEditable { return found }
        for child in view.subviews { if let found = field(in: child) { return found } }
        return nil
    }

    private func wait(_ seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Host: View {
        let model: MailModel
        let input: RecipientInput
        @State var text: String
        var body: some View { RecipientField(model: model, input: input, text: $text).frame(width: 500) }
    }

    private func show(_ text: String, model: MailModel, input: RecipientInput) throws -> (window: NSWindow, editor: NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(model: model, input: input, text: text))
        window.orderFrontRegardless()
        wait()
        let content = try #require(window.contentView)
        let textField = try #require(field(in: content))
        #expect(window.makeFirstResponder(textField))
        wait()
        return (window, try #require(textField.currentEditor() as? NSTextView))
    }

    /// A key as the keyboard sends it: through the text system's command for it.
    private func press(_ selector: Selector, in editor: NSTextView) {
        editor.doCommand(by: selector)
        wait()
    }

    @Test func backspaceOnAnEmptyFieldPicksOutThenRemovesTheLastPerson() throws {
        let input = RecipientInput()
        let shown = try show("Noor <noor@example.com>, maya@example.com", model: MailModel(environment: .preview()), input: input)
        defer { shown.window.close() }
        #expect(input.recipients.map(\.address) == ["noor@example.com", "maya@example.com"])
        #expect(input.isFocused)

        press(#selector(NSResponder.deleteBackward(_:)), in: shown.editor)
        #expect(input.selected == 1)
        #expect(input.recipients.count == 2)

        press(#selector(NSResponder.deleteBackward(_:)), in: shown.editor)
        #expect(input.recipients.map(\.address) == ["noor@example.com"])
        #expect(input.selected == nil)

        // And once more, twice, for the one that's left.
        press(#selector(NSResponder.deleteBackward(_:)), in: shown.editor)
        press(#selector(NSResponder.deleteBackward(_:)), in: shown.editor)
        #expect(input.recipients.isEmpty)
    }

    @Test func typingAnAddressAndACommaMakesABadge() throws {
        let input = RecipientInput()
        let shown = try show("", model: MailModel(environment: .preview()), input: input)
        defer { shown.window.close() }
        shown.editor.insertText("sam@example.com,", replacementRange: shown.editor.selectedRange())
        wait()
        #expect(input.recipients.map(\.address) == ["sam@example.com"])
        #expect(input.pending.isEmpty)
        #expect(shown.editor.string.isEmpty)
    }

    @Test func arrowsAndReturnPickASuggestedPerson() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let input = RecipientInput()
        let shown = try show("", model: model, input: input)
        defer { shown.window.close() }
        // Someone the sample mail knows, by the start of their name.
        let known = try #require(model.addressBook.suggestions(for: "no", limit: 6).first)
        shown.editor.insertText("no", replacementRange: shown.editor.selectedRange())
        wait()
        let matches = input.matches(in: model)
        #expect(matches.first == known)

        press(#selector(NSResponder.moveDown(_:)), in: shown.editor)
        #expect(input.highlighted == min(1, matches.count - 1))
        press(#selector(NSResponder.moveUp(_:)), in: shown.editor)
        #expect(input.highlighted == 0)
        press(#selector(NSResponder.insertNewline(_:)), in: shown.editor)
        #expect(input.recipients == [known])
        #expect(input.pending.isEmpty)
        #expect(shown.editor.string.isEmpty)
        // Still in the field, ready for the next person.
        #expect(input.isFocused)
    }
}
#endif
