import Foundation
import MailCore

/// The formatted text a message opens with when it comes back to the editor (Undo Send, a
/// failed send, a message brought back from Drafts with its formatting): its HTML read back,
/// inline pictures included. Read once, when the editor first appears.
@MainActor final class EditorStart {
    private var isRead = false
    private var text: NSAttributedString?

    func text(for draft: Draft) -> NSAttributedString? {
        if !isRead {
            isRead = true
            text = Self.formatted(draft)
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
