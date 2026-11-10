import MailCore
import SwiftUI
#if canImport(AppKit)
import AppKit

/// The message editor: the system's rich text view. `text` always holds the plain words
/// (drafts, the assistant and templates work with those); `html` holds a formatted
/// version only when something is actually formatted, so plain mail stays plain.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var html: String?
    var fontSize: CGFloat = 14
    var controller: RichTextController
    /// Esc while typing. A text view would otherwise keep the key for word completion, so the
    /// composer around it never hears it.
    var onEscape: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = true
        view.allowsUndo = true
        view.importsGraphics = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor]
        view.delegate = context.coordinator
        view.string = text
        controller.textView = view
        context.coordinator.onChange = { view in
            controller.changed(view, text: $text, html: $html)
        }
        context.coordinator.onEscape = onEscape
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.onEscape = onEscape
        // Text set from outside (the assistant, a template, a signature): start over as plain text.
        if view.string != text {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: view.typingAttributes))
            html = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: ((NSTextView) -> Void)?
        var onEscape: (() -> Void)?
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { onChange?(view) }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let onEscape else { return false }
            onEscape()
            return true
        }
    }
}

/// Formatting commands for the bar above the editor, and the HTML conversion.
@MainActor
final class RichTextController {
    weak var textView: NSTextView?
    private var pending: Task<Void, Never>?

    func changed(_ view: NSTextView, text: Binding<String>, html: Binding<String?>) {
        text.wrappedValue = view.string
        // Turning text into HTML takes a moment; do it once typing pauses.
        pending?.cancel()
        let storage = NSAttributedString(attributedString: view.attributedString())
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self != nil else { return }
            html.wrappedValue = Self.isFormatted(storage) ? Self.html(from: storage) : nil
        }
    }

    func toggle(_ trait: NSFontTraitMask) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        let manager = NSFontManager.shared
        if range.length == 0 {
            let font = (view.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 14)
            let has = manager.traits(of: font).contains(trait)
            view.typingAttributes[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            return
        }
        let first = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
        let adding = !manager.traits(of: first).contains(trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: 14)
            storage.addAttribute(.font, value: adding ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait), range: part)
        }
        storage.endEditing()
        view.didChangeText()
    }

    func toggleUnderline() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else { return }
        let has = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        storage.addAttribute(.underlineStyle, value: has ? 0 : NSUnderlineStyle.single.rawValue, range: range)
        view.didChangeText()
    }

    /// Starts each selected line with a bullet, or removes it.
    func toggleBullets() {
        guard let view = textView, let storage = view.textStorage else { return }
        let text = storage.string as NSString
        let lines = text.lineRange(for: view.selectedRange())
        var starts: [Int] = []
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, range, _, _ in starts.append(range.location) }
        let removing = starts.allSatisfy { text.length > $0 + 1 && text.substring(with: NSRange(location: $0, length: 2)) == "• " }
        storage.beginEditing()
        for start in starts.reversed() {
            if removing {
                storage.deleteCharacters(in: NSRange(location: start, length: 2))
            } else {
                storage.insert(NSAttributedString(string: "• ", attributes: view.typingAttributes), at: start)
            }
        }
        storage.endEditing()
        view.didChangeText()
    }

    func addLink(_ url: URL) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            let linked = NSAttributedString(string: url.absoluteString, attributes: view.typingAttributes.merging([.link: url]) { $1 })
            storage.insert(linked, at: range.location)
        } else {
            storage.addAttribute(.link, value: url, range: range)
        }
        view.didChangeText()
    }

    static func isFormatted(_ text: NSAttributedString) -> Bool {
        var formatted = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            if attributes[.link] != nil || (attributes[.underlineStyle] as? Int ?? 0) != 0
                || traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
                formatted = true
                stop.pointee = true
            }
        }
        return formatted
    }

    /// HTML for the formatted part, with the system font named in a way other devices understand.
    static func html(from text: NSAttributedString) -> String? {
        guard let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
              var html = String(data: data, encoding: .utf8) else { return nil }
        html = html.replacingOccurrences(of: "'.AppleSystemUIFont'", with: "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif")
            .replacingOccurrences(of: ".AppleSystemUIFont", with: "Helvetica")
        return html
    }
}

/// Bold, italic, underline, bullets, link.
struct FormattingBar: View {
    let controller: RichTextController
    @State private var asksForLink = false
    @State private var link = "https://"

    var body: some View {
        HStack(spacing: 0) {
            IconButton("bold", help: "Bold  ⌘B") { controller.toggle(.boldFontMask) }
            IconButton("italic", help: "Italic  ⌘I") { controller.toggle(.italicFontMask) }
            IconButton("underline", help: "Underline  ⌘U") { controller.toggleUnderline() }
            IconButton("list.bullet", help: "Bulleted list") { controller.toggleBullets() }
            IconButton("link", help: "Add a link") { asksForLink = true }
        }
        .alert("Add a link", isPresented: $asksForLink) {
            TextField("https://", text: $link)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                if let url = URL(string: link), url.scheme != nil { controller.addLink(url) }
                link = "https://"
            }
        }
    }
}
#else
/// iPhone and iPad: plain text for now.
struct RichTextEditor: View {
    @Binding var text: String
    @Binding var html: String?
    var fontSize: CGFloat = 14
    var controller: RichTextController
    var onEscape: (() -> Void)?

    var body: some View {
        TextEditor(text: $text).font(.system(size: fontSize)).scrollContentBackground(.hidden)
    }
}

@MainActor final class RichTextController {}

struct FormattingBar: View {
    let controller: RichTextController
    var body: some View { EmptyView() }
}
#endif
