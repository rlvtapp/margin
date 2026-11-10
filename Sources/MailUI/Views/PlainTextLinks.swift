import Foundation
import SwiftUI

/// Plain-text mail with its links clickable, and long ones shortened to where they go
/// ("outlook.office365.com/owa/…"), so a 300-character tracking address doesn't fill the page.
enum PlainTextLinks {
    static let longest = 48

    static func attributed(_ text: String) -> AttributedString {
        guard text.contains("http") || text.contains("www."),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = match.url, url.scheme == "https" || url.scheme == "http" else { continue }
            result += AttributedString(text[cursor..<range.lowerBound])
            var link = AttributedString(short(String(text[range]), url: url))
            link.link = url
            result += link
            cursor = range.upperBound
        }
        result += AttributedString(text[cursor...])
        return result
    }

    /// The link as written when it's short; otherwise its site and first path part.
    static func short(_ written: String, url: URL) -> String {
        guard written.count > longest, let host = url.host() else { return written }
        let first = url.pathComponents.dropFirst().first.map { "/" + $0 } ?? ""
        return host + (first.count > 24 ? "" : first) + "/…"
    }
}
