import Foundation
import MailCore

/// The email being forwarded, carried under what's written with its own formatting: colours,
/// tables, links and pictures go out as they came. Edit as Text turns it into quoted plain text
/// in the message instead, to trim it.
public struct ForwardedOriginal: Equatable, Sendable {
    /// "---------- Forwarded message ----------", From, Date, Subject and To.
    public var header: String
    /// The original's HTML, ready to sit inside another message.
    public var html: String
    /// The original as text, for the plain part and for Edit as Text.
    public var text: String

    init(message: MailMessage, body: MessageBody?) {
        let to = message.to.map(\.headerValue).joined(separator: ", ")
        header = "---------- Forwarded message ----------\nFrom: \(message.from.headerValue)\nDate: \(message.date.formatted())\nSubject: \(message.subject)"
            + (to.isEmpty ? "" : "\nTo: \(to)")
        text = body?.text ?? message.snippet
        html = Self.embeddable(body?.html ?? "")
    }

    /// The original as quoted plain text, as forwards used to be.
    var quotedText: String {
        "\n\n" + header + "\n\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }

    /// A whole HTML document made into a part of another one: what's in <body>, with the styles
    /// from <head> kept in front, scripts dropped, and pictures attached to the original
    /// (cid:) left out, since they don't travel with a forward.
    static func embeddable(_ html: String) -> String {
        var styles = ""
        if let head = html.range(of: "<head[^>]*>[\\s\\S]*?</head>", options: [.regularExpression, .caseInsensitive]) {
            let part = String(html[head])
            var search = part.startIndex..<part.endIndex
            while let style = part.range(of: "<style[^>]*>[\\s\\S]*?</style>", options: [.regularExpression, .caseInsensitive], range: search) {
                styles += part[style]
                search = style.upperBound..<part.endIndex
            }
        }
        var body = html
        if let open = body.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            body = String(body[open.upperBound...])
            if let close = body.range(of: "</body>", options: [.caseInsensitive, .backwards]) { body = String(body[..<close.lowerBound]) }
        } else {
            body = body.replacingOccurrences(of: "<head[^>]*>[\\s\\S]*?</head>", with: "", options: [.regularExpression, .caseInsensitive])
            body = body.replacingOccurrences(of: "</?html[^>]*>|<!doctype[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<img[^>]*src\\s*=\\s*[\"']cid:[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        return (styles + body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What's written, then the original underneath, in both the HTML and the plain part.
    func appended(to draft: Draft) -> Draft {
        var draft = draft
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        }
        let written = draft.html ?? "<div>\(escape(draft.text))</div>"
        draft.html = written + "<br><div class=\"margin-forward\"><div style=\"color:#666\">\(escape(header))</div><br>"
            + "<div style=\"border-left:2px solid #ccc;padding-left:12px;margin-left:0\">\(html)</div></div>"
        draft.text += quotedText
        return draft
    }
}
