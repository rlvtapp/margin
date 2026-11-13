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
    /// "Sent from Margin" at the end of the text: its "Margin" is shown as the link it'll be
    /// sent as.
    var linkedLastLine: String?
    /// The draft's attachments: pictures put in the text are kept there as inline parts.
    var attachments: Binding<[OutgoingAttachment]>?
    /// The signature at the end of the text, shown as it's sent: formatted, with its pictures.
    var signature: NamedSignature?
    /// Formatted text to start with (a signature being edited); `text` holds its words.
    var initial: NSAttributedString?

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
        if let initial {
            view.textStorage?.setAttributedString(initial)
        } else {
            view.string = text
        }
        controller.textView = view
        context.coordinator.onChange = { view in
            controller.changed(view, text: $text, html: $html, attachments: attachments)
        }
        let linked = Self.linkLastLine(linkedLastLine, in: view)
        if Self.showSignature(signature, in: view) || linked { controller.changed(view, text: $text, html: $html, attachments: attachments) }
        context.coordinator.onEscape = onEscape
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        context.coordinator.onEscape = onEscape
        // Text set from outside (the assistant, a template, another signature): what's new comes
        // in as plain text, and what stayed the same keeps its formatting.
        if view.string != text {
            let old = view.string as NSString, new = text as NSString
            var same = 0
            while same < min(old.length, new.length), old.character(at: same) == new.character(at: same) { same += 1 }
            if same > 0, CFStringIsSurrogateHighCharacter(old.character(at: same - 1)) { same -= 1 }
            storage.replaceCharacters(in: NSRange(location: same, length: old.length - same),
                                      with: NSAttributedString(string: new.substring(from: same), attributes: Self.normal(fontSize)))
            Self.showSignature(signature, in: view)
            Self.linkLastLine(linkedLastLine, in: view)
            controller.changed(view, text: $text, html: $html, attachments: attachments)
        }
    }

    static func normal(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
    }

    /// Shows a formatted signature at the end of the text as it's sent. Its words (with a
    /// U+FFFC where each picture goes) are already there; this gives them their formatting and
    /// pictures. True when it did.
    @discardableResult
    static func showSignature(_ signature: NamedSignature?, in view: NSTextView) -> Bool {
        guard let signature, signature.rich != nil, let storage = view.textStorage else { return false }
        let words = signature.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = (view.string as NSString).range(of: words, options: .backwards)
        guard !words.isEmpty, range.location != NSNotFound else { return false }
        let shown = NSMutableAttributedString(attributedString: SignatureText.attributed(signature))
        guard shown.string == words else { return false }
        shown.addAttribute(EmailHTMLWriter.signatureKey, value: true, range: NSRange(location: 0, length: shown.length))
        let selection = view.selectedRanges
        storage.replaceCharacters(in: range, with: shown)
        view.selectedRanges = selection
        return true
    }

    /// Links "Margin" in the last line when the text ends with `line`. True when it did.
    @discardableResult
    static func linkLastLine(_ line: String?, in view: NSTextView) -> Bool {
        guard let line, !line.isEmpty, let storage = view.textStorage, let url = URL(string: MailModel.marginSite),
              view.string.hasSuffix(line) else { return false }
        let start = view.string.index(view.string.endIndex, offsetBy: -line.count)
        let words = MailModel.linkRange(in: line)
        let lower = view.string.index(start, offsetBy: line.distance(from: line.startIndex, to: words.lowerBound))
        let upper = view.string.index(start, offsetBy: line.distance(from: line.startIndex, to: words.upperBound))
        storage.addAttribute(.link, value: url, range: NSRange(lower..<upper, in: view.string))
        return true
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

    func changed(_ view: NSTextView, text: Binding<String>, html: Binding<String?>, attachments: Binding<[OutgoingAttachment]>? = nil) {
        if text.wrappedValue != view.string { text.wrappedValue = view.string }
        // Turning text into HTML takes a moment; do it once typing pauses.
        pending?.cancel()
        let storage = NSAttributedString(attributedString: view.attributedString())
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self != nil else { return }
            let written = Self.isFormatted(storage) ? EmailHTMLWriter.write(storage) : nil
            html.wrappedValue = written?.html
            // Pictures in the text are the draft's inline parts: added when put in, gone when deleted.
            if let attachments {
                let others = attachments.wrappedValue.filter { !($0.contentID ?? "").hasSuffix(EmailHTMLWriter.inlineSuffix) }
                let updated = others + (written?.images ?? [])
                if updated != attachments.wrappedValue { attachments.wrappedValue = updated }
            }
        }
    }

    // MARK: More tools

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }

    /// A font family by name; nil for the editor's normal one.
    func setFont(_ name: String?) {
        changeFonts { font in
            let manager = NSFontManager.shared
            let traits = manager.traits(of: font)
            var base = name.flatMap { NSFont(name: $0, size: font.pointSize) ?? manager.font(withFamily: $0, traits: [], weight: 5, size: font.pointSize) }
                ?? .systemFont(ofSize: font.pointSize)
            if traits.contains(.boldFontMask) { base = manager.convert(base, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { base = manager.convert(base, toHaveTrait: .italicFontMask) }
            return base
        }
    }

    /// The system's font window, for any font on this Mac.
    func showFonts() {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    /// Changes the paragraphs the selection touches, or what's typed next.
    private func changeParagraphs(_ change: (NSMutableParagraphStyle) -> Void) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: view.selectedRange())
        func changed(_ style: NSParagraphStyle?) -> NSParagraphStyle {
            let copy = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            change(copy)
            return copy
        }
        view.typingAttributes[.paragraphStyle] = changed(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        guard range.length > 0 else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
            storage.addAttribute(.paragraphStyle, value: changed(value as? NSParagraphStyle), range: part)
        }
        storage.endEditing()
        view.didChangeText()
    }

    /// Moves the paragraphs in or out by one step (28 points).
    func indent(_ steps: Int) {
        changeParagraphs { style in
            let indent = max(0, style.headIndent + CGFloat(steps) * 28)
            style.headIndent = indent
            style.firstLineHeadIndent = indent
        }
    }

    func setLineSpacing(_ multiple: CGFloat) {
        changeParagraphs { $0.lineHeightMultiple = multiple }
    }

    /// The widest a picture put in the text is shown.
    var widestPicture: CGFloat = 480
    /// Pictures are kept no bigger than they're shown (at twice the size, for sharp screens), as
    /// a signature's are.
    var keepsPicturesSmall = false

    /// Puts pictures in the text where the cursor is, shown at most `widestPicture` wide.
    func insertPictures(_ urls: [URL]) {
        guard let view = textView, let storage = view.textStorage else { return }
        var at = view.selectedRange().location
        storage.beginEditing()
        for url in urls {
            guard var image = NSImage(contentsOf: url) else { continue }
            if keepsPicturesSmall { image = SignatureText.smaller(image, shownAt: min(widestPicture, image.size.width)) }
            let attachment = NSTextAttachment()
            attachment.image = image
            let scale = min(1, widestPicture / max(image.size.width, 1))
            attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.append(NSAttributedString(string: "\n", attributes: view.typingAttributes))
            storage.insert(piece, at: at)
            at += piece.length
        }
        storage.endEditing()
        view.setSelectedRange(NSRange(location: at, length: 0))
        view.didChangeText()
    }

    /// Shows the selected pictures (all of them when none is selected) at `width` points wide.
    func resizePictures(to width: CGFloat) {
        guard let view = textView, let storage = view.textStorage else { return }
        let selected = view.selectedRange()
        let range = selected.length > 0 ? selected : NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.attachment, in: range) { value, part, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image, image.size.width > 0 else { return }
            let resized = NSTextAttachment()
            resized.image = image
            resized.bounds = CGRect(x: 0, y: 0, width: width, height: (image.size.height * width / image.size.width).rounded())
            storage.addAttribute(.attachment, value: resized, range: part)
        }
        storage.endEditing()
        view.didChangeText()
    }

    /// The system's emoji and symbols picker, typing into the message.
    func showEmoji() {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        NSApp.orderFrontCharacterPalette(nil)
    }

    /// Back to normal text: links and pictures stay.
    func clearFormatting() {
        guard let view = textView, let storage = view.textStorage else { return }
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: EmailHTMLWriter.baseSize), .foregroundColor: NSColor.labelColor]
        view.typingAttributes = normal
        let range = view.selectedRange()
        guard range.length > 0 else { return }
        storage.beginEditing()
        for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .strikethroughStyle, .paragraphStyle] {
            storage.removeAttribute(key, range: range)
        }
        storage.addAttributes(normal, range: range)
        storage.endEditing()
        view.didChangeText()
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

    /// Applies an attribute to the selection, or to what's typed next when nothing is selected.
    private func apply(_ key: NSAttributedString.Key, _ value: Any?) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            view.typingAttributes[key] = value
            return
        }
        storage.beginEditing()
        if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
        storage.endEditing()
        view.didChangeText()
    }

    /// The text colour; nil for the normal one.
    func setColor(_ color: NSColor?) { apply(.foregroundColor, color ?? NSColor.labelColor) }

    /// A highlight behind the text; nil for none.
    func setHighlight(_ color: NSColor?) { apply(.backgroundColor, color) }

    func toggleStrikethrough() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        let at = range.length > 0 ? (storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0)
            : (view.typingAttributes[.strikethroughStyle] as? Int ?? 0)
        apply(.strikethroughStyle, at != 0 ? nil : NSUnderlineStyle.single.rawValue)
    }

    /// Changes the font's size or family, keeping bold and italic.
    private func changeFonts(_ change: (NSFont) -> NSFont) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            view.typingAttributes[.font] = change((view.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 14))
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            storage.addAttribute(.font, value: change((value as? NSFont) ?? .systemFont(ofSize: 14)), range: part)
        }
        storage.endEditing()
        view.didChangeText()
    }

    func setSize(_ size: CGFloat) {
        changeFonts { NSFontManager.shared.convert($0, toSize: size) }
    }

    enum Family: CaseIterable { case sans, serif, mono }

    func setFamily(_ family: Family) {
        changeFonts { font in
            let manager = NSFontManager.shared
            let traits = manager.traits(of: font)
            var base: NSFont = switch family {
            case .sans: .systemFont(ofSize: font.pointSize)
            case .serif: NSFont(name: "Georgia", size: font.pointSize) ?? .systemFont(ofSize: font.pointSize)
            case .mono: .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            }
            if traits.contains(.boldFontMask) { base = manager.convert(base, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { base = manager.convert(base, toHaveTrait: .italicFontMask) }
            return base
        }
    }

    /// Aligns the paragraphs the selection touches.
    func setAlignment(_ alignment: NSTextAlignment) {
        changeParagraphs { $0.alignment = alignment }
    }

    /// Numbers each selected line ("1. ", "2. "…), or removes the numbers.
    func toggleNumbers() {
        guard let view = textView, let storage = view.textStorage else { return }
        let text = storage.string as NSString
        let lines = text.lineRange(for: view.selectedRange())
        var starts: [Int] = []
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, range, _, _ in starts.append(range.location) }
        func number(at start: Int) -> NSRange? {
            let rest = text.substring(from: start) as NSString
            let match = rest.range(of: "^[0-9]+\\. ", options: .regularExpression)
            return match.location == NSNotFound ? nil : NSRange(location: start, length: match.length)
        }
        let removing = !starts.isEmpty && starts.allSatisfy { number(at: $0) != nil }
        storage.beginEditing()
        for (index, start) in starts.enumerated().reversed() {
            if removing, let existing = number(at: start) {
                storage.deleteCharacters(in: existing)
            } else if !removing {
                storage.insert(NSAttributedString(string: "\(index + 1). ", attributes: view.typingAttributes), at: start)
            }
        }
        storage.endEditing()
        view.didChangeText()
    }

    static func isFormatted(_ text: NSAttributedString) -> Bool {
        var formatted = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let color = attributes[.foregroundColor] as? NSColor
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            let alignment = paragraph?.alignment
            if attributes[.link] != nil || attributes[.attachment] != nil
                || (paragraph.map { $0.headIndent > 0 || ($0.lineHeightMultiple > 0 && abs($0.lineHeightMultiple - 1) > 0.01) } ?? false) || (attributes[.underlineStyle] as? Int ?? 0) != 0
                || (attributes[.strikethroughStyle] as? Int ?? 0) != 0 || attributes[.backgroundColor] != nil
                || (color != nil && color != NSColor.labelColor)
                || (alignment != nil && alignment != .natural && alignment != .left)
                || (font.map { abs($0.pointSize - 14) > 0.5 || !($0.familyName ?? "").hasPrefix(".") } ?? false)
                || traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
                formatted = true
                stop.pointee = true
            }
        }
        return formatted
    }

    /// HTML for the formatted part (`EmailHTMLWriter`).
    static func html(from text: NSAttributedString) -> String? {
        EmailHTMLWriter.write(text).html
    }
}

/// Undo and redo; font, size; bold, italic, underline, strikethrough; colour and highlight;
/// alignment, lists, indents, line spacing; link, picture, emoji; clear formatting.
struct FormattingBar: View {
    let controller: RichTextController
    @State private var asksForLink = false
    @State private var picksPicture = false
    @State private var link = "https://"

    /// Relevate's named colours (the same set as its web editor), in shades that read on white
    /// and on dark: what most people open mail on.
    static var colors: [(name: String, value: NSColor)] {
        [(String(localized: "Gray"), NSColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 1)),
         (String(localized: "Brown"), NSColor(srgbRed: 0.55, green: 0.36, blue: 0.22, alpha: 1)),
         (String(localized: "Orange"), NSColor(srgbRed: 0.85, green: 0.45, blue: 0.0, alpha: 1)),
         (String(localized: "Yellow"), NSColor(srgbRed: 0.72, green: 0.56, blue: 0.0, alpha: 1)),
         (String(localized: "Green"), NSColor(srgbRed: 0.10, green: 0.55, blue: 0.25, alpha: 1)),
         (String(localized: "Blue"), NSColor(srgbRed: 0.10, green: 0.35, blue: 0.85, alpha: 1)),
         (String(localized: "Purple"), NSColor(srgbRed: 0.45, green: 0.25, blue: 0.80, alpha: 1)),
         (String(localized: "Pink"), NSColor(srgbRed: 0.85, green: 0.20, blue: 0.55, alpha: 1)),
         (String(localized: "Red"), NSColor(srgbRed: 0.80, green: 0.15, blue: 0.15, alpha: 1))]
    }

    static var highlights: [(name: String, value: NSColor)] {
        [(String(localized: "Gray"), NSColor(srgbRed: 0.90, green: 0.90, blue: 0.91, alpha: 1)),
         (String(localized: "Brown"), NSColor(srgbRed: 0.93, green: 0.87, blue: 0.80, alpha: 1)),
         (String(localized: "Orange"), NSColor(srgbRed: 1.0, green: 0.86, blue: 0.70, alpha: 1)),
         (String(localized: "Yellow"), NSColor(srgbRed: 1.0, green: 0.93, blue: 0.45, alpha: 1)),
         (String(localized: "Green"), NSColor(srgbRed: 0.75, green: 0.95, blue: 0.70, alpha: 1)),
         (String(localized: "Blue"), NSColor(srgbRed: 0.75, green: 0.87, blue: 1.0, alpha: 1)),
         (String(localized: "Purple"), NSColor(srgbRed: 0.87, green: 0.80, blue: 1.0, alpha: 1)),
         (String(localized: "Pink"), NSColor(srgbRed: 1.0, green: 0.80, blue: 0.88, alpha: 1)),
         (String(localized: "Red"), NSColor(srgbRed: 1.0, green: 0.80, blue: 0.78, alpha: 1))]
    }

    /// Fonts that look the same on the reader's device, most of them on every one.
    static let fonts = ["Helvetica", "Arial", "Verdana", "Trebuchet MS", "Georgia", "Times New Roman", "Courier New"]
    static let sizes: [CGFloat] = [10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36]

    private func menu<Items: View>(_ symbol: String, help: LocalizedStringKey, @ViewBuilder items: () -> Items) -> some View {
        Menu { items() } label: {
            Image(systemName: symbol).font(.system(size: Look.size(13))).foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(help))
    }

    private var divider: some View {
        Rectangle().fill(Line.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    var body: some View {
        HStack(spacing: 0) {
            IconButton("arrow.uturn.backward", help: "Undo  ⌘Z") { controller.undo() }
            IconButton("arrow.uturn.forward", help: "Redo  ⇧⌘Z") { controller.redo() }
            divider
            menu("textformat", help: "Font") {
                Button("Normal") { controller.setFont(nil) }
                Divider()
                ForEach(Self.fonts, id: \.self) { name in
                    Button { controller.setFont(name) } label: { Text(verbatim: name).font(.custom(name, size: 13)) }
                }
                Divider()
                Button("Show Fonts…") { controller.showFonts() }
            }
            menu("textformat.size", help: "Text size") {
                ForEach(Self.sizes, id: \.self) { size in
                    Button { controller.setSize(size) } label: {
                        size == EmailHTMLWriter.baseSize ? Text("\(Int(size)) (Normal)") : Text(verbatim: "\(Int(size))")
                    }
                }
            }
            divider
            IconButton("bold", help: "Bold  ⌘B") { controller.toggle(.boldFontMask) }
            IconButton("italic", help: "Italic  ⌘I") { controller.toggle(.italicFontMask) }
            IconButton("underline", help: "Underline  ⌘U") { controller.toggleUnderline() }
            IconButton("strikethrough", help: "Strikethrough") { controller.toggleStrikethrough() }
            menu("paintpalette", help: "Text color") {
                Button("Default") { controller.setColor(nil) }
                ForEach(Self.colors, id: \.name) { color in
                    Button(color.name) { controller.setColor(color.value) }
                }
            }
            menu("highlighter", help: "Highlight") {
                Button("None") { controller.setHighlight(nil) }
                ForEach(Self.highlights, id: \.name) { color in
                    Button(color.name) { controller.setHighlight(color.value) }
                }
            }
            divider
            menu("text.alignleft", help: "Alignment") {
                Button { controller.setAlignment(.left) } label: { Label("Align Left", systemImage: "text.alignleft") }
                Button { controller.setAlignment(.center) } label: { Label("Center", systemImage: "text.aligncenter") }
                Button { controller.setAlignment(.right) } label: { Label("Align Right", systemImage: "text.alignright") }
            }
            IconButton("list.bullet", help: "Bulleted list") { controller.toggleBullets() }
            IconButton("list.number", help: "Numbered list") { controller.toggleNumbers() }
            IconButton("decrease.indent", help: "Decrease indent") { controller.indent(-1) }
            IconButton("increase.indent", help: "Increase indent") { controller.indent(1) }
            menu("arrow.up.and.down.text.horizontal", help: "Line spacing") {
                Button("Single") { controller.setLineSpacing(1) }
                Button { controller.setLineSpacing(1.15) } label: { Text(verbatim: "1.15") }
                Button { controller.setLineSpacing(1.5) } label: { Text(verbatim: "1.5") }
                Button("Double") { controller.setLineSpacing(2) }
            }
            divider
            IconButton("link", help: "Add a link") { asksForLink = true }
            IconButton("photo", help: "Insert picture") { picksPicture = true }
            IconButton("face.smiling", help: "Emoji") { controller.showEmoji() }
            IconButton("eraser", help: "Clear formatting") { controller.clearFormatting() }
        }
        .alert("Add a link", isPresented: $asksForLink) {
            TextField("https://", text: $link)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                if let url = URL(string: link), url.scheme != nil { controller.addLink(url) }
                link = "https://"
            }
        }
        .fileImporter(isPresented: $picksPicture, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { controller.insertPictures(urls) }
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
    var linkedLastLine: String?
    var attachments: Binding<[OutgoingAttachment]>?
    var signature: NamedSignature?

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
