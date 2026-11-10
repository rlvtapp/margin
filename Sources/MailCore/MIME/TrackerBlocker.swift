import Foundation

/// Takes the tracking out of HTML mail, whether or not pictures are loaded: tracking pixels are
/// removed (tiny or hidden images, and images from known open-tracking services), tracked links
/// go straight to where they point, and tracking parameters are dropped from every link.
public enum TrackerBlocker {
    /// Hosts and paths of services that report when mail is opened or clicked.
    static let trackerPatterns = [
        "list-manage.com/track", "mailchimp.com/track", "sendgrid.net/wf/open", "sendgrid.net/ls/click", "mandrillapp.com/track",
        "mailgun.org/o/", "/o/eJ", "hubspotlinks.com", "hubspotemail.net", "hs-analytics", "t.sidekickopen", "mailtrack.io",
        "superhuman.com", "getnotify.com", "yesware.com", "mixmax.com", "streak.com", "bananatag.com", "cirrusinsight.com",
        "boomeranggmail.com", "mailtag.io", "doubleclick.net", "google-analytics.com", "facebook.com/tr", "px.ads.linkedin.com",
        "emltrk.com", "returnpath.net", "litmus.com", "exacttarget.com", "createsend1.com", "cmail19.com", "cmail20.com",
        "klaviyo.com/open", "trk.klclick", "customeriomail.com", "sparkpostmail.com", "mailjet.com/oo", "sendinblue.com/tr",
        "sibforms", "constantcontact.com/v2/track", "mktotracking", "mkto-", "pardot.com", "intercom-mail.com", "postmarkapp.com/open",
        "amazonses.com/open", "awstrack.me", "/open.gif", "/o.gif", "/pixel.gif", "/track/open", "/beacon",
    ]

    /// Query parameters that only exist to track who clicked.
    static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "mc_cid", "mc_eid", "fbclid", "gclid",
        "dclid", "msclkid", "_hsenc", "_hsmi", "mkt_tok", "oly_enc_id", "oly_anon_id", "vero_id", "trk", "trkCampaign", "sc_campaign",
    ]

    /// Query parameters that tracking redirects carry the real destination in.
    static let destinationParameters = ["url", "u", "redirect", "redirect_url", "target", "dest", "destination", "link", "to", "r"]

    public struct Result: Sendable {
        public var html: String
        /// Where each removed tracker came from, by host ("list-manage.com"), most frequent first.
        public var blocked: [String]
        public var cleanedLinks: Int
    }

    public static func clean(_ html: String) -> Result {
        var output = html
        var hosts: [String] = []

        // Tracking pixels: images that are tiny, hidden, or from a tracking service.
        let images = matches(in: output, pattern: #"<img\b[^>]*>"#)
        for tag in images.reversed() {
            let text = String(output[tag])
            guard let source = attribute("src", in: text), source.lowercased().hasPrefix("http") else { continue }
            let lower = text.lowercased()
            let tiny = lower.range(of: #"(width|height)\s*=\s*["']?[01](px)?["'\s>/]"#, options: .regularExpression) != nil
                || lower.range(of: #"(width|height)\s*:\s*[01]px"#, options: .regularExpression) != nil
            let hidden = lower.range(of: #"display\s*:\s*none|visibility\s*:\s*hidden|opacity\s*:\s*0[;"']"#, options: .regularExpression) != nil
            let known = trackerPatterns.contains { source.lowercased().contains($0.lowercased()) }
            guard tiny || hidden || known else { continue }
            hosts.append(URL(string: source)?.host().map(shortHost) ?? "unknown")
            output.replaceSubrange(tag, with: "")
        }
        // Backgrounds from tracking services.
        for pattern in [#"url\(\s*["']?(https?://[^"')\s]+)["']?\s*\)"#] {
            for range in matches(in: output, pattern: pattern).reversed() {
                let text = String(output[range])
                guard trackerPatterns.contains(where: { text.lowercased().contains($0.lowercased()) }) else { continue }
                hosts.append(URL(string: text.replacingOccurrences(of: #"url\(\s*["']?|["']?\s*\)"#, with: "", options: .regularExpression))?.host().map(shortHost) ?? "unknown")
                output.replaceSubrange(range, with: "none")
            }
        }

        // Links: go straight to the destination, without tracking parameters.
        var cleaned = 0
        for range in matches(in: output, pattern: #"href\s*=\s*"(https?://[^"]+)""#).reversed() {
            let text = String(output[range])
            guard let start = text.firstIndex(of: "\""), let raw = Optional(String(text[text.index(after: start)...].dropLast())) else { continue }
            let original = raw.replacingOccurrences(of: "&amp;", with: "&")
            let clean = cleanLink(original)
            guard clean != original else { continue }
            cleaned += 1
            output.replaceSubrange(range, with: "href=\"\(clean.replacingOccurrences(of: "&", with: "&amp;"))\"")
        }

        var counts: [String: Int] = [:]
        for host in hosts { counts[host, default: 0] += 1 }
        let ordered = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        return Result(html: output, blocked: ordered, cleanedLinks: cleaned)
    }

    /// A link without its tracking: the destination a redirect carries, minus tracking parameters.
    public static func cleanLink(_ link: String) -> String {
        guard var components = URLComponents(string: link) else { return link }
        let lower = link.lowercased()
        let isTracker = trackerPatterns.contains { lower.contains($0.lowercased()) }
            || ["/click", "/redirect", "/track", "/ls/click", "/c/"].contains { (components.path.lowercased()).contains($0) }
        if isTracker, let target = components.queryItems?.first(where: { destinationParameters.contains($0.name.lowercased()) })?.value,
           let destination = URL(string: target), destination.scheme?.hasPrefix("http") == true {
            return cleanLink(destination.absoluteString)
        }
        if let items = components.queryItems {
            let kept = items.filter { !trackingParameters.contains($0.name) && !$0.name.lowercased().hasPrefix("utm_") }
            if kept.count != items.count {
                components.queryItems = kept.isEmpty ? nil : kept
                return components.string ?? link
            }
        }
        return link
    }

    private static func shortHost(_ host: String) -> String {
        let parts = host.split(separator: ".")
        return parts.count > 2 ? parts.suffix(2).joined(separator: ".") : host
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    private static func matches(in text: String, pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}
