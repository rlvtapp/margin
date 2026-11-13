import MailCore
#if canImport(AppKit)
import AppKit

/// Formatted signatures on the Mac: turning what's in the editor into a signature, and back.
@MainActor
enum SignatureText {
    /// Where a picture was, in a saved signature: its content ID and shown size ("id 120 40").
    /// The picture itself is kept once, in the signature's `pictures`.
    static let pictureKey = NSAttributedString.Key("MarginSignaturePicture")
    /// The widest a signature's picture is shown.
    static let widestPicture: CGFloat = 300

    /// What's in the editor as a signature: the words, the HTML and pictures that are sent, and
    /// the formatting to edit it again. Plain words make a plain signature.
    static func signature(named name: String, from text: NSAttributedString) -> NamedSignature {
        let trimmed = trim(text)
        var signature = NamedSignature(name: name, text: trimmed.string)
        guard trimmed.length > 0, RichTextController.isFormatted(trimmed) else { return signature }
        let written = EmailHTMLWriter.write(trimmed)
        signature.html = written.html
        signature.pictures = written.images.isEmpty ? nil : written.images
        signature.rich = archive(trimmed)
        return signature
    }

    /// The signature as the editor shows it, formatting and pictures included. Plain text for a
    /// plain one; an HTML-only one (written by hand, or from before) is read from its HTML.
    static func attributed(_ signature: NamedSignature, fontSize: CGFloat = EmailHTMLWriter.baseSize) -> NSAttributedString {
        if let rich = signature.rich, let text = unarchive(rich, pictures: signature.pictures ?? []) { return text }
        if let html = signature.html, !html.isEmpty, let text = fromHTML(html, pictures: signature.pictures ?? []) { return text }
        return NSAttributedString(string: signature.text, attributes: normal(fontSize))
    }

    /// The editor's own normal text.
    static func normal(_ size: CGFloat = EmailHTMLWriter.baseSize) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
    }

    /// Without blank lines and spaces at either end.
    static func trim(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        let keep = CharacterSet.whitespacesAndNewlines.inverted
        let first = string.rangeOfCharacter(from: keep)
        guard first.location != NSNotFound else { return NSAttributedString() }
        let last = string.rangeOfCharacter(from: keep, options: .backwards)
        return text.attributedSubstring(from: NSRange(location: first.location, length: NSMaxRange(last) - first.location))
    }

    // MARK: Saving

    static func archive(_ text: NSAttributedString) -> Data? {
        let copy = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: copy.length)
        copy.removeAttribute(EmailHTMLWriter.signatureKey, range: all)
        copy.enumerateAttribute(.attachment, in: all) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            copy.removeAttribute(.attachment, range: range)
            guard let part = EmailHTMLWriter.pictureData(attachment) else { return }
            let size = attachment.bounds.width > 0 ? attachment.bounds.size : (attachment.image?.size ?? .zero)
            copy.addAttribute(pictureKey, value: "\(part.id) \(Int(size.width.rounded())) \(Int(size.height.rounded()))", range: range)
        }
        return try? NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(attributedString: copy), requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data, pictures: [OutgoingAttachment]) -> NSAttributedString? {
        let classes: [AnyClass] = [NSAttributedString.self, NSMutableAttributedString.self, NSFont.self, NSColor.self,
                                   NSParagraphStyle.self, NSMutableParagraphStyle.self, NSTextTab.self, NSURL.self,
                                   NSString.self, NSNumber.self, NSDictionary.self, NSArray.self, NSShadow.self]
        guard let archived = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)) as? NSAttributedString else { return nil }
        let text = NSMutableAttributedString(attributedString: archived)
        let all = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(pictureKey, in: all) { value, range, _ in
            guard let value = value as? String else { return }
            text.removeAttribute(pictureKey, range: range)
            let parts = value.split(separator: " ")
            guard parts.count == 3, let picture = pictures.first(where: { $0.contentID == String(parts[0]) }),
                  let image = NSImage(data: picture.data) else { return }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: 0, width: Double(parts[1]) ?? image.size.width, height: Double(parts[2]) ?? image.size.height)
            text.addAttribute(.attachment, value: attachment, range: range)
        }
        return text
    }

    // MARK: HTML

    /// HTML read into the editor: a signature written as HTML, or pasted from elsewhere. Its
    /// near-black text becomes the editor's normal colour, so it still reads in dark mode.
    static func fromHTML(_ html: String, pictures: [OutgoingAttachment] = []) -> NSAttributedString? {
        var source = HTMLSanitizer.sanitize(html).html
        for picture in pictures {
            guard let id = picture.contentID else { continue }
            source = source.replacingOccurrences(of: "cid:\(id)", with: "data:\(picture.mimeType);base64,\(picture.data.base64EncodedString())")
        }
        guard let read = try? NSAttributedString(data: Data(source.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil) else { return nil }
        let text = NSMutableAttributedString(attributedString: trim(read))
        let all = NSRange(location: 0, length: text.length)
        let manager = NSFontManager.shared
        text.enumerateAttributes(in: all) { attributes, range, _ in
            if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
               0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent < 0.25 {
                text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            } else if attributes[.foregroundColor] == nil {
                text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
            // Semibold (font-weight 600) reads as bold, which is what's sent.
            if let font = attributes[.font] as? NSFont, !manager.traits(of: font).contains(.boldFontMask),
               let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat, weight >= 0.3 {
                text.addAttribute(.font, value: manager.convert(NSFont.systemFont(ofSize: font.pointSize), toHaveTrait: .boldFontMask), range: range)
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if attachment.image == nil, let data = attachment.fileWrapper?.regularFileContents { attachment.image = NSImage(data: data) }
                if let size = attachment.image?.size, size.width > 0 {
                    let scale = min(1, widestPicture / size.width)
                    attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
                }
            }
        }
        return text
    }

    // MARK: Pictures

    /// A picture made small enough to keep in a signature: at most twice as wide as it's shown,
    /// for sharp screens.
    static func smaller(_ image: NSImage, shownAt width: CGFloat) -> NSImage {
        let pixels = width * 2
        guard image.size.width > pixels else { return image }
        let size = NSSize(width: pixels, height: (image.size.height * pixels / image.size.width).rounded())
        // A photo stays without transparency, so it's sent as a JPEG.
        let alpha = image.representations.compactMap { $0 as? NSBitmapImageRep }.first?.hasAlpha ?? true
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let smaller = NSImage(size: size)
        smaller.addRepresentation(bitmap)
        return smaller
    }
}
#endif

extension MailModel {
    /// Once, on the Mac: a default signature that was written as HTML becomes one the editor
    /// can show while writing, when reading its HTML gives the same words. Others keep working
    /// as before (the HTML takes the words' place when sending).
    func upgradeFormattedSignatures() {
        #if canImport(AppKit)
        guard !environment.isPreview, !environment.defaults.bool(forKey: "formattedSignaturesUpgraded") else { return }
        environment.defaults.set(true, forKey: "formattedSignaturesUpgraded")
        for (index, account) in accounts.enumerated() {
            guard let signature = account.defaultSignature, signature.isFormatted, signature.rich == nil,
                  !HTMLSanitizer.sanitize(signature.html ?? "").hasRemoteContent,
                  let read = SignatureText.fromHTML(signature.html ?? "", pictures: signature.pictures ?? []) else { continue }
            let upgraded = SignatureText.signature(named: NamedSignature.defaultName, from: read)
            guard upgraded.plainText == signature.plainText.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            accounts[index].setSignature(upgraded)
            try? environment.accounts.save(accounts)
        }
        #endif
    }
}
