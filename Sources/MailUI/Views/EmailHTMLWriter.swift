#if canImport(AppKit)
import AppKit
import MailCore

/// Turns what's in the editor into email HTML: every style written on the element itself (mail
/// apps drop `<style>` blocks), line spacing and indents kept, and pictures as inline parts
/// (`cid:`) next to the HTML instead of the file links the system's writer makes.
enum EmailHTMLWriter {
    /// The editor's normal text: what the HTML leaves unsaid.
    static let baseSize: CGFloat = 14
    static let baseFamily = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
    /// Inline pictures Margin made: their content IDs end with this.
    static let inlineSuffix = "@margin-inline"

    struct Result: Equatable {
        var html: String
        var images: [OutgoingAttachment]
    }

    static func write(_ text: NSAttributedString) -> Result {
        var images: [OutgoingAttachment] = []
        var blocks: [String] = []
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let style = range.length > 0 ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            let content = range.length == 0 ? "<br>" : runs(text, in: range, images: &images)
            blocks.append("<div style=\"\(paragraphCSS(style))\">\(content)</div>")
        }
        if string.length == 0 || string.hasSuffix("\n") { blocks.append("<div style=\"margin:0\"><br></div>") }
        let html = "<div style=\"font-family:\(baseFamily);font-size:\(Int(baseSize))px\">\n" + blocks.joined(separator: "\n") + "\n</div>"
        return Result(html: html, images: images)
    }

    static func paragraphCSS(_ style: NSParagraphStyle?) -> String {
        var css = ["margin:0"]
        guard let style else { return css[0] }
        if style.headIndent > 0 { css.append("margin-left:\(Int(style.headIndent))px") }
        switch style.alignment {
        case .center: css.append("text-align:center")
        case .right: css.append("text-align:right")
        case .justified: css.append("text-align:justify")
        default: break
        }
        if style.lineHeightMultiple > 0, abs(style.lineHeightMultiple - 1) > 0.01 {
            css.append("line-height:\(String(format: "%.2g", style.lineHeightMultiple))")
        }
        return css.joined(separator: ";")
    }

    private static func runs(_ text: NSAttributedString, in range: NSRange, images: inout [OutgoingAttachment]) -> String {
        var out = ""
        text.enumerateAttributes(in: range) { attributes, part, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let tag = picture(attachment, index: images.count, images: &images) { out += tag }
                return
            }
            var piece = escape((text.string as NSString).substring(with: part))
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            if traits.contains(.boldFontMask) { piece = "<b>\(piece)</b>" }
            if traits.contains(.italicFontMask) { piece = "<i>\(piece)</i>" }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 { piece = "<u>\(piece)</u>" }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { piece = "<s>\(piece)</s>" }
            var css: [String] = []
            if let font {
                if let family = family(of: font) { css.append("font-family:\(family)") }
                if abs(font.pointSize - baseSize) > 0.5 { css.append("font-size:\(Int(font.pointSize.rounded()))px") }
            }
            if let color = attributes[.foregroundColor] as? NSColor, color != .labelColor, let hex = hex(color) { css.append("color:\(hex)") }
            if let background = attributes[.backgroundColor] as? NSColor, let hex = hex(background) { css.append("background-color:\(hex)") }
            if !css.isEmpty { piece = "<span style=\"\(css.joined(separator: ";"))\">\(piece)</span>" }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { piece = "<a href=\"\(escape(url))\">\(piece)</a>" }
            }
            out += piece
        }
        return out
    }

    /// The picture as an inline part, named by its bytes so writing the HTML again keeps the
    /// same name; nil when it has no picture.
    private static func picture(_ attachment: NSTextAttachment, index: Int, images: inout [OutgoingAttachment]) -> String? {
        guard let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let isPhoto = bitmap.bitsPerPixel >= 24 && !bitmap.hasAlpha
        guard let data = isPhoto ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                                 : bitmap.representation(using: .png, properties: [:]) else { return nil }
        let id = "picture-\(String(fnv(data), radix: 16))\(inlineSuffix)"
        if !images.contains(where: { $0.contentID == id }) {
            images.append(OutgoingAttachment(filename: "picture-\(index + 1).\(isPhoto ? "jpg" : "png")",
                                             mimeType: isPhoto ? "image/jpeg" : "image/png", data: data, contentID: id))
        }
        let shown = attachment.bounds.width > 0 ? attachment.bounds.width : image.size.width
        let width = Int(min(shown, 600).rounded())
        return "<img src=\"cid:\(id)\" width=\"\(width)\" alt=\"\" style=\"max-width:100%;height:auto\">"
    }

    /// A family other devices understand; nil for the editor's normal one.
    static func family(of font: NSFont) -> String? {
        let name = font.familyName ?? ""
        if name.hasPrefix(".") || name == "Helvetica Neue" { return nil }
        let generic = font.fontDescriptor.symbolicTraits.contains(.monoSpace) ? "monospace"
            : ["Georgia", "Times New Roman", "Times", "Palatino", "Baskerville", "New York"].contains(name) ? "serif" : "sans-serif"
        return "'\(name)', \(generic)"
    }

    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func part(_ value: CGFloat) -> String { String(format: "%02x", Int((max(0, min(1, value)) * 255).rounded())) }
        return "#" + part(rgb.redComponent) + part(rgb.greenComponent) + part(rgb.blueComponent)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// FNV-1a: a short, stable name from a picture's bytes.
    static func fnv(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}
#endif
