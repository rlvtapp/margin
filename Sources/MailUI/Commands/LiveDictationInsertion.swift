#if os(macOS)
import AppKit

/// Interim speech replaces only this session's text. The final insertion is one normal
/// editor change, so Undo restores the selection that dictation replaced.
@MainActor
final class LiveDictationInsertion {
    private weak var editor: NSTextView?
    private let selection: NSRange
    private let original: String
    private var interim: String?
    private var finished = false

    init(editor: NSTextView) {
        self.editor = editor
        selection = editor.selectedRange()
        original = editor.string
    }

    private var expectedText: String {
        guard let interim else { return original }
        return (original as NSString).replacingCharacters(in: selection, with: interim)
    }

    private var expectedSelection: NSRange {
        guard let interim else { return selection }
        return NSRange(location: selection.location + interim.utf16.count, length: 0)
    }

    private func unchanged(_ editor: NSTextView) -> Bool {
        !finished && editor.string == expectedText && editor.selectedRange() == expectedSelection
    }

    private func focused(_ editor: NSTextView) -> Bool {
        editor.window?.firstResponder === editor && (NSApp.keyWindow == nil || NSApp.keyWindow === editor.window)
    }

    @discardableResult
    func update(_ words: String) -> Bool {
        guard let editor, unchanged(editor), focused(editor) else { return false }
        guard interim != words else { return true }
        let range = NSRange(location: selection.location, length: interim?.utf16.count ?? selection.length)
        withoutUndo(in: editor) { editor.insertText(words, replacementRange: range) }
        interim = words
        return true
    }

    func commit(_ words: String) {
        guard let editor, unchanged(editor), focused(editor) else { return }
        restore(in: editor)
        if !words.isEmpty {
            editor.breakUndoCoalescing()
            editor.insertText(words, replacementRange: selection)
            editor.breakUndoCoalescing()
        }
        finished = true
    }

    /// Never overwrite typing, selection changes, or edits made by another control.
    func cancel() {
        guard let editor, unchanged(editor) else { return }
        restore(in: editor)
        finished = true
    }

    private func restore(in editor: NSTextView) {
        guard let interim else { return }
        let range = NSRange(location: selection.location, length: interim.utf16.count)
        let replaced = (original as NSString).substring(with: selection)
        withoutUndo(in: editor) {
            editor.insertText(replaced, replacementRange: range)
            editor.setSelectedRange(selection)
        }
        self.interim = nil
    }

    private func withoutUndo(in editor: NSTextView, _ change: () -> Void) {
        let undo = editor.undoManager
        let enabled = undo?.isUndoRegistrationEnabled == true
        if enabled { undo?.disableUndoRegistration() }
        defer { if enabled { undo?.enableUndoRegistration() } }
        change()
    }
}
#endif
