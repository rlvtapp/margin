import Foundation

/// Making a signature, and finding the one someone already uses in their sent mail.
public enum SignatureTools {
    public struct Details: Sendable {
        public var name, role, company, phone, website: String
        public init(name: String = "", role: String = "", company: String = "", phone: String = "", website: String = "") {
            self.name = name; self.role = role; self.company = company; self.phone = phone; self.website = website
        }
    }

    /// A clean signature from a few details, as plain text and as HTML.
    public static func make(_ d: Details) -> (text: String, html: String) {
        let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let roleLine = [trimmed(d.role), trimmed(d.company)].filter { !$0.isEmpty }.joined(separator: " · ")
        let contact = [trimmed(d.phone), trimmed(d.website)].filter { !$0.isEmpty }.joined(separator: " · ")
        let lines = [trimmed(d.name), roleLine, contact].filter { !$0.isEmpty }
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.45;color:#555\">"
        if !trimmed(d.name).isEmpty { html += "<div style=\"font-weight:600;color:#222\">\(escape(trimmed(d.name)))</div>" }
        if !roleLine.isEmpty { html += "<div>\(escape(roleLine))</div>" }
        var parts: [String] = []
        if !trimmed(d.phone).isEmpty {
            let digits = trimmed(d.phone).filter { $0.isNumber || $0 == "+" }
            parts.append("<a href=\"tel:\(digits)\" style=\"color:#555;text-decoration:none\">\(escape(trimmed(d.phone)))</a>")
        }
        if !trimmed(d.website).isEmpty {
            let site = trimmed(d.website)
            let link = site.hasPrefix("http") ? site : "https://" + site
            parts.append("<a href=\"\(escape(link))\" style=\"color:#2F6FEB;text-decoration:none\">\(escape(site))</a>")
        }
        if !parts.isEmpty { html += "<div>\(parts.joined(separator: " · "))</div>" }
        html += "</div>"
        return (lines.joined(separator: "\n"), html)
    }

    /// The signature someone ends their sent mail with: the longest block of closing lines that
    /// comes back in enough of their messages. Nil when there isn't a clear one.
    public static func find(in sentTexts: [String]) -> String? {
        let tails: [[String]] = sentTexts.map { text in
            var kept: [String] = []
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(">") || t.hasPrefix("---------- Forwarded") { break }
                if (t.hasPrefix("On ") && t.hasSuffix("wrote:")) || (t.hasPrefix("Op ") && t.hasSuffix("schreef:")) { break }
                kept.append(t)
            }
            let lines = kept.filter { !$0.isEmpty && $0 != "--" && $0 != "-- " }
            return Array(lines.suffix(8))
        }.filter { $0.count >= 2 }
        guard tails.count >= 2 else { return nil }
        let needed = max(2, tails.count / 3)
        for length in stride(from: 6, through: 2, by: -1) {
            var counts: [[String]: Int] = [:]
            for tail in tails where tail.count >= length { counts[Array(tail.suffix(length)), default: 0] += 1 }
            if let best = counts.filter({ $0.value >= needed }).max(by: { $0.value < $1.value })?.key {
                // A sign-off like "Thanks," on its own isn't part of the signature.
                var block = best
                if let first = block.first, first.count < 20, first.hasSuffix(",") { block.removeFirst() }
                return block.count >= 1 ? block.joined(separator: "\n") : nil
            }
        }
        return nil
    }
}
