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
        // Event handlers: onclick=, onload=, onerror=…
        html = html.replacing(pattern: "\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "")
        // Script URLs in links and sources.
        html = html.replacing(pattern: "(href|src|action|background)\\s*=\\s*([\"']?)\\s*(javascript|vbscript|livescript):[^\"'\\s>]*", with: "$1=$2#")

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
