import Testing
@testable import MailCore

@Suite struct HTMLMarkdownTests {
    @Test func keepsHeadingsBoldListsAndLinks() {
        let html = """
        <html><head><style>p{color:red}</style></head><body>
        <h1>Five soups</h1><p>A <b>lentil</b> soup &amp; four more.</p>
        <img src="https://track.example/p.gif">
        <ul><li>Lentil</li><li>Leek</li></ul>
        <p><a href="https://slowcook.example/soups">Read the recipes</a> or <a href="javascript:alert(1)">this</a></p>
        <p>5*2 [sic]</p></body></html>
        """
        let markdown = HTMLText.markdown(html)
        #expect(markdown.contains("**Five soups**"))
        #expect(markdown.contains("A **lentil** soup & four more."))
        #expect(markdown.contains("• Lentil\n• Leek"))
        #expect(markdown.contains("[Read the recipes](https://slowcook.example/soups)"))
        #expect(!markdown.contains("javascript"))
        #expect(!markdown.contains("track.example"))
        #expect(markdown.contains("5\\*2 \\[sic\\]"))
    }
}
