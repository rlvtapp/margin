import Foundation
import Testing
@testable import MailCore

/// What stands between a stranger's email and the Mac: the HTML cleaner, attachment names and
/// kinds, and parsers that must never crash on whatever arrives.
@Suite struct SafetyTests {
    // MARK: Email HTML

    @Test func knownWaysAroundTheCleanerAreClosed() {
        let attacks = [
            #"<svg/onload=alert(1)>"#,
            #"<img src="x"onerror=alert(1)>"#,
            #"<body/onpageshow=alert(1)>"#,
            #"<a href="jav&#x61;script:alert(1)">x</a>"#,
            #"<a href="&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1)">x</a>"#,
            "<a href=\"java\tscript:alert(1)\">x</a>",
            "<a href=\"java\nscript:alert(1)\">x</a>",
            #"<a href="javascript&colon;alert(1)">x</a>"#,
            #"<a href='  JaVaScRiPt:alert(1)'>x</a>"#,
            #"<a href=javascript:alert(1)>x</a>"#,
            #"<a href="vbscript:msgbox(1)">x</a>"#,
            #"<a href="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==">x</a>"#,
            #"<a href="data:image/svg+xml,<svg onload=alert(1)>">x</a>"#,
            #"<button formaction="javascript:alert(1)">x</button>"#,
            #"<div srcdoc="<script>alert(1)</script>">x</div>"#,
            #"<svg><a xlink:href="javascript:alert(1)">x</a></svg>"#,
            #"<scr<script>x</script>ipt>alert(1)</script>"#,
            #"<META HTTP-EQUIV="Refresh" CONTENT="0; URL=https://evil.example">"#,
            #"<object data="https://evil.example/x"></object><embed src="x"><applet code="x"></applet>"#,
        ]
        for attack in attacks {
            let safe = HTMLSanitizer.sanitize(attack).html.lowercased()
            #expect(!safe.contains("javascript:") && !safe.contains("vbscript:"), "\(attack) → \(safe)")
            #expect(!safe.contains("onload") && !safe.contains("onerror") && !safe.contains("onpageshow"), "\(attack) → \(safe)")
            #expect(!safe.contains("<script") && !safe.contains("srcdoc") && !safe.contains("data:text/html"), "\(attack) → \(safe)")
            #expect(!safe.contains("refresh") && !safe.contains("<object") && !safe.contains("<embed") && !safe.contains("<applet"), "\(attack) → \(safe)")
        }
    }

    @Test func ordinaryMailComesThroughUntouched() {
        let mail = #"""
        <p>Tickets are <a href="https://shop.example/online=1?a=b">here</a>.</p>
        <img src="data:image/png;base64,iVBORw0KGgo=" alt="logo"><p>We're online= every day; one more thing.</p>
        <a href="mailto:hi@example.com">Write</a>
        """#
        let safe = HTMLSanitizer.sanitize(mail).html
        #expect(safe.contains(#"href="https://shop.example/online=1?a=b""#))
        #expect(safe.contains("data:image/png;base64"))
        #expect(safe.contains("mailto:hi@example.com"))
        #expect(!HTMLSanitizer.isDangerousURL("https://example.com/javascript:/x"))
        #expect(HTMLSanitizer.isDangerousURL(" \u{0001}javascript:alert(1)"))
    }

    // MARK: Attachments

    @Test func attachmentNamesSayWhatTheyAre() {
        let tricked = "invoice\u{202E}fdp.command"   // shows as "invoicedmmoc.pdf"
        #expect(AttachmentSafety.safeFilename(tricked) == "invoicefdp.command")
        #expect(AttachmentSafety.isRisky(filename: tricked))
        let traversal = AttachmentSafety.safeFilename("../../.ssh/authorized_keys")
        #expect(!traversal.contains("/") && !traversal.hasPrefix("."))
        #expect(!AttachmentSafety.safeFilename(".zshrc").hasPrefix("."))
        #expect(AttachmentSafety.safeFilename("a\u{0000}b\u{200B}c.pdf") == "abc.pdf")
    }

    @Test func appsAndScriptsAreRiskyDocumentsAreNot() {
        for name in ["Setup.app", "run.command", "install.sh", "Update.pkg", "x.scpt", "link.webloc", "profile.mobileconfig",
                     "tool.py", "INVOICE.PDF.COMMAND", "a.terminal", "macro.workflow"] {
            #expect(AttachmentSafety.isRisky(filename: name), "\(name)")
        }
        for name in ["invoice.pdf", "photo.jpeg", "notes.txt", "sheet.xlsx", "deck.key", "archive.zip", "README", "image.HEIC"] {
            #expect(!AttachmentSafety.isRisky(filename: name), "\(name)")
        }
    }

    // MARK: Parsers never crash

    /// A fixed seed, so a failure can be run again exactly.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static let sample = Array("""
    From: Noor <noor@post.example>\r
    To: me@home.example\r
    Subject: =?utf-8?B?SGVsbG8g8J+Riw==?=\r
    MIME-Version: 1.0\r
    Content-Type: multipart/mixed; boundary="b1"\r
    \r
    --b1\r
    Content-Type: multipart/alternative; boundary="b2"\r
    \r
    --b2\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    Hi =E2=80=94 see you at 10:00.\r
    --b2\r
    Content-Type: text/html; charset=utf-8\r
    \r
    <p>Hi <b>there</b></p>\r
    --b2--\r
    --b1\r
    Content-Type: text/calendar; method=REQUEST\r
    \r
    BEGIN:VCALENDAR\r
    BEGIN:VEVENT\r
    DTSTART:20261113T100000Z\r
    SUMMARY:Review\r
    END:VEVENT\r
    END:VCALENDAR\r
    --b1\r
    Content-Type: application/pdf; name="a.pdf"\r
    Content-Disposition: attachment; filename="a.pdf"\r
    Content-Transfer-Encoding: base64\r
    \r
    JVBERi0xLjQK\r
    --b1--\r
    """.utf8)

    @Test func corruptedAndRandomMailNeverCrashesTheParsers() {
        var random = Seeded(state: 20261112)
        for round in 0..<400 {
            var bytes: [UInt8]
            if round % 2 == 0 {
                // The sample with bytes changed, cut or repeated, as broken or hostile mail is.
                bytes = Self.sample
                for _ in 0..<Int.random(in: 1...40, using: &random) {
                    let index = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0..<4, using: &random) {
                    case 0: bytes[index] = UInt8.random(in: 0...255, using: &random)
                    case 1: bytes.removeSubrange(index..<min(bytes.count, index + Int.random(in: 1...30, using: &random)))
                    case 2: bytes.insert(contentsOf: Array(bytes[index..<min(bytes.count, index + 20)]), at: index)
                    default: bytes.insert(contentsOf: Array("--b1\r\n--b2\r\n=?utf-8?Q?=FF?=\r\n".utf8), at: index)
                    }
                    if bytes.isEmpty { bytes = [0] }
                }
            } else {
                bytes = (0..<Int.random(in: 0...2000, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            }
            let message = MIMEMessage.parse(bytes)
            _ = message.text.count
            let text = String(decoding: bytes, as: UTF8.self)
            _ = HTMLSanitizer.sanitize(text)
            _ = HTMLText.plain(text)
            _ = HTMLText.snippet(text)
            _ = CalendarInvite.parse(text)
            _ = try? IMAPParser.parse(bytes)
        }
    }

    @Test func deepNestingIsHandled() {
        // A message nested thousands of times deep must not exhaust the stack.
        var bytes = Array("Content-Type: multipart/mixed; boundary=\"x\"\r\n\r\n".utf8)
        for _ in 0..<3000 { bytes += Array("--x\r\nContent-Type: multipart/mixed; boundary=\"x\"\r\n\r\n".utf8) }
        _ = MIMEMessage.parse(bytes)
        _ = HTMLSanitizer.sanitize(String(repeating: "<div>", count: 20000))
    }
}
