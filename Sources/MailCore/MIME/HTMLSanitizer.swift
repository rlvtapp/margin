import Foundation

/// HTML mail made safe to show. The renderer also runs with scripts off and the network
/// blocked; this is the second lock, so neither one has to be perfect alone.
public struct SafeHTML: Hashable, Sendable {
    public var html: String
    /// Images, stylesheets and fonts the message would fetch from the internet. Each fetch
    /// tells the sender you opened it, so they stay blocked until allowed.
    public var remoteResources: Int
    /// Remote images that look like tracking pixels (1×1, or hidden).
    public var trackers: Int
    /// The message says it was designed for dark backgrounds.
    public var supportsDarkMode: Bool
    /// Pictures of any kind: images, picture and SVG elements, background images. Only mail
    /// without them is turned dark, so a picture is never shown with its colours turned around.
    public var hasPictures = false
    /// Trackers taken out by tracker blocking, by where they came from ("list-manage.com").
    public var blockedTrackers: [String] = []
    /// Links that went through a tracker and now go straight to where they point.
    public var cleanedLinks = 0

    public var hasRemoteContent: Bool { remoteResources > 0 }
}

public enum HTMLSanitizer {
    /// With `blockTrackers`, tracking pixels are removed and links untracked (see TrackerBlocker),
    /// so loading pictures no longer tells the sender you opened the mail.
    public static func sanitize(_ input: String, blockTrackers: Bool = false) -> SafeHTML {
        var html = input

        // Elements that run code, embed other pages, or redirect.
        for tag in ["script", "iframe", "object", "embed", "applet", "frameset", "frame", "noscript", "template"] {
            html = html.replacing(pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: "")
            html = html.replacing(pattern: "<\(tag)\\b[^>]*/?>", with: "")
        }
        html = html.replacing(pattern: "<meta\\b[^>]*http-equiv\\s*=\\s*[\"']?refresh[^>]*>", with: "")
        html = html.replacing(pattern: "<base\\b[^>]*>", with: "")
        // Forms could post what you type to anywhere; keep their content, drop the form.
        html = html.replacing(pattern: "</?form\\b[^>]*>", with: "")
        // Event handlers: onclick=, onload=, onerror=… Also right after a slash or a quote
        // (<svg/onload=…>, src="x"onerror=…), which browsers accept as well.
        html = html.replacing(pattern: "(<[a-z][a-z0-9-]*)/+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "$1 ")
        html = html.replacing(pattern: "(?<=[\\s\"'])on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: " ")
        // An inline page instead of the mail.
        html = html.replacing(pattern: "\\s+srcdoc\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "")
        // Script and page URLs in links and sources, however they're disguised.
        html = neutralizingURLs(html)

        let remote = count(in: html, pattern: "(src|background|srcset)\\s*=\\s*[\"']?\\s*https?://")
            + count(in: html, pattern: "url\\(\\s*[\"']?\\s*https?://")
            + count(in: html, pattern: "<link\\b[^>]*href\\s*=\\s*[\"']?https?://")
        let trackers = count(in: html, pattern: "<img\\b(?=[^>]*https?://)(?=[^>]*(width\\s*=\\s*[\"']?[01][\"'\\s>/]|height\\s*=\\s*[\"']?[01][\"'\\s>/]|display\\s*:\\s*none))[^>]*>")
        // <meta name="color-scheme" content="light dark">, CSS `color-scheme: light dark`,
        // or styles written for a dark appearance.
        let dark = count(in: html, pattern: "<meta\\b[^>]*color-scheme[^>]*content\\s*=\\s*[\"'][^\"']*dark")
            + count(in: html, pattern: "color-scheme\\s*:[^;}\"']*dark")
            + count(in: html, pattern: "prefers-color-scheme\\s*:\\s*dark") > 0
        var safe = SafeHTML(html: html, remoteResources: remote, trackers: trackers, supportsDarkMode: dark)
        safe.hasPictures = count(in: html, pattern: "<(img|picture|svg|video|canvas)\\b|background-image\\s*:|\\bbackground\\s*=|url\\(") > 0
        if blockTrackers {
            let cleaned = TrackerBlocker.clean(html)
            safe.html = cleaned.html
            safe.blockedTrackers = cleaned.blocked
            safe.cleanedLinks = cleaned.cleanedLinks
            safe.trackers = max(trackers, cleaned.blocked.count)
            safe.remoteResources = count(in: cleaned.html, pattern: "(src|background|srcset)\\s*=\\s*[\"']?\\s*https?://")
                + count(in: cleaned.html, pattern: "url\\(\\s*[\"']?\\s*https?://")
                + count(in: cleaned.html, pattern: "<link\\b[^>]*href\\s*=\\s*[\"']?https?://")
        }
        return safe
    }

    /// Attributes that point somewhere. A value that turns out to be a script (`javascript:`),
    /// or a whole page (`data:text/html`), once its character references, spaces and control
    /// characters are undone, becomes "#". Pictures as data stay.
    private static let urlAttribute = try? NSRegularExpression(
        pattern: "(\\b(?:href|src|action|formaction|background|poster|xlink:href|dynsrc|lowsrc)\\s*=\\s*)(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
        options: [.caseInsensitive])

    static func neutralizingURLs(_ html: String) -> String {
        guard let regex = urlAttribute else { return html }
        let text = html as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let valueRange = match.range(at: 2)
            var value = text.substring(with: valueRange)
            let quote = value.first.flatMap { $0 == "\"" || $0 == "'" ? String($0) : nil } ?? ""
            if !quote.isEmpty { value = String(value.dropFirst().dropLast()) }
            guard isDangerousURL(value) else { continue }
            result += text.substring(with: NSRange(location: last, length: match.range.location - last))
            result += text.substring(with: match.range(at: 1)) + quote + "#" + quote
            last = match.range.location + match.range.length
        }
        guard last > 0 else { return html }
        return result + text.substring(from: last)
    }

    /// Whether a link or source runs script or replaces the mail with another page.
    static func isDangerousURL(_ raw: String) -> Bool {
        // Browsers ignore spaces, tabs, newlines and control characters inside the scheme, and
        // decode references like &#x6A; or &colon; first.
        let decoded = HTMLText.decodeEntities(raw.replacingOccurrences(of: "&colon;", with: ":", options: .caseInsensitive)
            .replacingOccurrences(of: "&tab;", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "&newline;", with: "", options: .caseInsensitive))
        let compact = String(decoded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
            .lowercased()
        for scheme in ["javascript:", "vbscript:", "livescript:", "data:text/html", "data:application/xhtml", "data:image/svg+xml"] where compact.hasPrefix(scheme) {
            return true
        }
        return false
    }

    private static func count(in text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

extension String {
    fileprivate func replacing(pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
