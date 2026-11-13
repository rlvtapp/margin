import Foundation

/// Writes a draft as an RFC 5322 message: UTF-8 text in quoted-printable, CRLF line ends,
/// and multipart/mixed with base64 parts when there are attachments.
public enum MessageBuilder {
    public static func build(_ draft: Draft, date: Date = Date(), messageID: String? = nil, boundary: String? = nil) -> [UInt8] {
        let id = messageID ?? "\(UUID().uuidString.lowercased())@\(draft.from.domain.isEmpty ? "localhost" : draft.from.domain)"
        var lines: [String] = [
            "Date: \(MailDate.format(date))",
            "From: \(draft.from.headerValue)",
        ]
        if !draft.to.isEmpty { lines.append("To: \(draft.to.map(\.headerValue).joined(separator: ", "))") }
        if !draft.cc.isEmpty { lines.append("Cc: \(draft.cc.map(\.headerValue).joined(separator: ", "))") }
        // Bcc is never written into the message; it only goes into the envelope.
        lines.append("Subject: \(MIMEWords.encodeIfNeeded(draft.subject))")
        lines.append("Message-ID: <\(id)>")
        if let inReplyTo = draft.inReplyTo { lines.append("In-Reply-To: <\(inReplyTo)>") }
        if !draft.references.isEmpty { lines.append("References: \(draft.references.map { "<\($0)>" }.joined(separator: " "))") }
        lines.append("MIME-Version: 1.0")

        let marker = boundary ?? "margin-\(UUID().uuidString.lowercased())"
        var textPart = [
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            // A picture in the text is a placeholder character there; the HTML part shows it.
            QuotedPrintable.encode(draft.text.replacingOccurrences(of: "\u{FFFC}", with: "")),
        ]
        // An invitation reply: the text, plus the iCalendar part calendar apps act on.
        if let calendar = draft.calendar {
            let alternative = "cal" + String(marker.reversed())
            // The iTIP method the calendar names (REQUEST, REPLY, CANCEL…); REPLY when it names none.
            let method = CalendarInvite.unfold(calendar).first { $0.uppercased().hasPrefix("METHOD:") }
                .map { String($0.dropFirst(7)).uppercased().filter { $0.isASCII && ($0.isLetter || $0 == "-") } }?.nilIfEmpty ?? "REPLY"
            textPart = [
                "Content-Type: multipart/alternative; boundary=\"\(alternative)\"",
                "",
                "--\(alternative)",
            ] + textPart + [
                "--\(alternative)",
                "Content-Type: text/calendar; method=\(method); charset=utf-8",
                "Content-Transfer-Encoding: quoted-printable",
                "",
                QuotedPrintable.encode(calendar),
                "--\(alternative)--",
            ]
        } else if let emoji = draft.reaction {
            // A reaction: the text, Gmail's reaction part, then the HTML if any, the order Gmail
            // recommends so apps showing only the first or the last part still show text.
            let alternative = "rx" + String(marker.reversed())
            var parts = [
                "Content-Type: multipart/alternative; boundary=\"\(alternative)\"",
                "",
                "--\(alternative)",
            ] + textPart + [
                "--\(alternative)",
                "Content-Type: \(MailReaction.gmailType)",
                "Content-Transfer-Encoding: base64",
                "",
                MailReaction.gmailJSON(emoji).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]),
            ]
            if let html = draft.html {
                parts += [
                    "--\(alternative)",
                    "Content-Type: text/html; charset=utf-8",
                    "Content-Transfer-Encoding: quoted-printable",
                    "",
                    QuotedPrintable.encode(html),
                ]
            }
            textPart = parts + ["--\(alternative)--"]
        } else if let html = draft.html {
            // Formatted mail: the same message as plain text and as HTML; readers pick one.
            // A boundary must never start with another one in the same message (RFC 2046 §5.1.1).
            let alternative = "alt" + String(marker.reversed())
            textPart = [
                "Content-Type: multipart/alternative; boundary=\"\(alternative)\"",
                "",
                "--\(alternative)",
            ] + textPart + [
                "--\(alternative)",
                "Content-Type: text/html; charset=utf-8",
                "Content-Transfer-Encoding: quoted-printable",
                "",
                QuotedPrintable.encode(html),
                "--\(alternative)--",
            ]
        }
        // Pictures shown inside the HTML travel next to it in multipart/related (RFC 2387), each
        // with the Content-ID the HTML points at; other files are ordinary attachments.
        let inline = draft.html == nil ? [] : draft.attachments.filter { $0.contentID != nil }
        let files = draft.attachments.filter { draft.html == nil || $0.contentID == nil }
        if !inline.isEmpty {
            let related = "rel" + String(marker.reversed())
            var part = [
                "Content-Type: multipart/related; boundary=\"\(related)\"; type=\"multipart/alternative\"",
                "",
                "--\(related)",
            ] + textPart
            for file in inline {
                part += [
                    "--\(related)",
                    "Content-Type: \(file.mimeType); name=\"\(Self.quotedName(file.filename))\"",
                    "Content-Disposition: inline; \(Self.filenameParameter(file.filename))",
                    "Content-ID: <\(file.contentID ?? "")>",
                    "Content-Transfer-Encoding: base64",
                    "",
                    file.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]),
                ]
            }
            part.append("--\(related)--")
            textPart = part
        }
        if files.isEmpty {
            lines += textPart
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(marker)\"")
            lines.append("")
            lines.append("--\(marker)")
            lines += textPart
            for file in files {
                lines.append("--\(marker)")
                lines.append("Content-Type: \(file.mimeType); name=\"\(Self.quotedName(file.filename))\"")
                lines.append("Content-Disposition: attachment; \(Self.filenameParameter(file.filename))")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(file.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
            }
            lines.append("--\(marker)--")
        }
        return Array((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// `filename="plan.pdf"`, or the RFC 2231 form for names that aren't plain ASCII.
    static func filenameParameter(_ name: String) -> String {
        if name.unicodeScalars.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "\\" }) { return "filename=\"\(name)\"" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        allowed.formIntersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        return "filename*=utf-8''\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file")"
    }

    static func quotedName(_ name: String) -> String {
        MIMEWords.encodeIfNeeded(name.replacingOccurrences(of: "\"", with: "'"))
    }
}
