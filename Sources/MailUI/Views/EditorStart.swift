import Foundation
import MailCore

/// The formatted text a message opens with when it comes back to the editor (Undo Send, a
/// failed send, a message brought back from Drafts with its formatting): its HTML read back,
/// inline pictures included. Taken once, when the editor first appears.
///
/// The reading itself happens in the model when the message opens (`prepareEditorStart`), never
/// here: this is asked for while SwiftUI draws the editor, and reading HTML runs AppKit's HTML
/// importer, which isn't safe to run in the middle of a view update.
@MainActor final class EditorStart {
    private var isRead = false
    private var text: NSAttributedString?

    func text(for draft: Draft, in model: MailModel) -> NSAttributedString? {
        if !isRead {
            isRead = true
            text = model.preparedEditorStart(for: draft)
        }
        // Only while the words are still the same: an editor made again later starts from them.
        return text?.string == draft.text ? text : nil
    }

    /// The draft's HTML as editor text, or nil to start from its plain words: when there's no
    /// HTML, or reading it back wouldn't give the same words (the editor keeps the two in step).
    static func formatted(_ draft: Draft) -> NSAttributedString? {
        #if canImport(AppKit)
        guard let html = draft.html, !html.isEmpty else { return nil }
        let pictures = draft.attachments.filter { ($0.contentID ?? "").hasSuffix(EmailHTMLWriter.inlineSuffix) }
        guard let read = SignatureText.fromHTML(html, pictures: pictures), read.string == draft.text else { return nil }
        return read
        #else
        return nil
        #endif
    }
}

extension MailModel {
    /// Reads a message's formatting back from its HTML as it opens in the composer or the reply
    /// bar, so the editor finds it ready. Only the open messages' formatting is kept.
    func prepareEditorStart(_ state: ComposeState?) {
        let open = Set([compose, reply].compactMap { $0?.draft.html })
        editorStarts = editorStarts.filter { open.contains($0.key) }
        guard let draft = state?.draft, let html = draft.html, !html.isEmpty, editorStarts[html] == nil,
              let text = EditorStart.formatted(draft) else { return }
        editorStarts[html] = text
    }

    func preparedEditorStart(for draft: Draft) -> NSAttributedString? {
        draft.html.flatMap { editorStarts[$0] }
    }
}
