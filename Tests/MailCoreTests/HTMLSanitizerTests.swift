import Testing
@testable import MailCore

@Suite struct HTMLSanitizerTests {
    @Test func removesCodeAndKeepsContent() {
        let input = """
        <html><head><meta http-equiv="refresh" content="0;url=https://x.example"><base href="https://x.example/">
        <script>alert(1)</script><SCRIPT src="https://x.example/a.js"></SCRIPT></head>
        <body onload="steal()"><p onclick='go()'>Hello <b>there</b></p>
        <iframe src="https://x.example/frame"></iframe><embed src="x.swf">
        <a href="javascript:alert(1)">bad</a> <a href=" JavaScript:alert(1)">bad2</a> <a href="https://ok.example">ok</a>
        <form action="https://x.example/post"><input name="q">Search</form></body></html>
        """
        let safe = HTMLSanitizer.sanitize(input).html.lowercased()
        for forbidden in ["<script", "alert(1)</script", "onload", "onclick", "<iframe", "<embed", "javascript:", "http-equiv", "<base", "<form"] {
            #expect(!safe.contains(forbidden), "\(forbidden)")
        }
        #expect(safe.contains("hello <b>there</b>"))
        #expect(safe.contains("https://ok.example"))
        #expect(safe.contains("search"))
    }

    @Test func countsRemoteContentAndTrackers() {
        let input = """
        <img src="https://cdn.example/hero.jpg" width="600">
        <img src="https://t.example/open.gif" width="1" height="1">
        <img src='https://t.example/pixel' style="display:none">
        <div style="background-image: url('https://cdn.example/bg.png')"></div>
        <link rel="stylesheet" href="https://cdn.example/s.css">
        <img src="data:image/png;base64,AAAA">
        """
        let safe = HTMLSanitizer.sanitize(input)
        #expect(safe.remoteResources == 5)
        #expect(safe.trackers == 2)
        #expect(safe.hasRemoteContent)
        #expect(!HTMLSanitizer.sanitize("<p>Only <img src=\"data:image/png;base64,AA\"></p>").hasRemoteContent)
    }

    @Test func noticesDarkModeSupport() {
        #expect(HTMLSanitizer.sanitize("<meta name=\"color-scheme\" content=\"light dark\">").supportsDarkMode)
        #expect(HTMLSanitizer.sanitize("<style>@media (prefers-color-scheme: dark) { body { color: #fff } }</style>").supportsDarkMode)
        #expect(!HTMLSanitizer.sanitize("<p>Plain</p>").supportsDarkMode)
    }
}

@Suite struct DarkModePictureTests {
    @Test func notesPicturesSoTheyAreNeverInverted() {
        #expect(HTMLSanitizer.sanitize("<p>Hey Kaan!</p><ul><li>Get groceries</li></ul>").hasPictures == false)
        #expect(HTMLSanitizer.sanitize("<p>Hi</p><img src=\"cid:logo\">").hasPictures)
        #expect(HTMLSanitizer.sanitize("<td style=\"background-image: url(cid:x)\">Sale</td>").hasPictures)
        #expect(HTMLSanitizer.sanitize("<table background=\"cid:x\"><tr><td>Hi</td></tr></table>").hasPictures)
        #expect(HTMLSanitizer.sanitize("<svg viewBox=\"0 0 1 1\"></svg>").hasPictures)
    }
}
