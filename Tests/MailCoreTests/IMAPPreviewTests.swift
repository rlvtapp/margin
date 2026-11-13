import Foundation
import Testing
@testable import MailCore

@Suite struct IMAPPreviewTests {
    private func leaf(_ type: String, _ subtype: String, charset: String = "utf-8", encoding: String = "7BIT",
                      disposition: IMAPValue = .none) -> IMAPValue {
        .list([.quoted(type), .quoted(subtype), .list([.quoted("CHARSET"), .quoted(charset)]), .none, .none,
               .quoted(encoding), .atom("100"), .atom("5"), .none, disposition, .none])
    }

    @Test func picksThePlainPartOfAnAlternative() throws {
        let structure = IMAPValue.list([leaf("TEXT", "PLAIN"), leaf("TEXT", "HTML"), .quoted("ALTERNATIVE")])
        let part = try #require(IMAPTextPart.find(in: structure))
        #expect(part.section == "1")
        #expect(!part.isHTML)
    }

    @Test func findsHTMLInsideMixedWithAttachments() throws {
        let attachment = leaf("TEXT", "PLAIN", disposition: .list([.quoted("ATTACHMENT"), .none]))
        let structure = IMAPValue.list([.list([leaf("TEXT", "HTML", encoding: "BASE64"), .quoted("ALTERNATIVE")]), attachment, .quoted("MIXED")])
        let part = try #require(IMAPTextPart.find(in: structure))
        #expect(part.section == "1.1")
        #expect(part.isHTML)
    }

    @Test func singlePartIsSectionOne() throws {
        #expect(try #require(IMAPTextPart.find(in: leaf("TEXT", "PLAIN"))).section == "1")
    }

    @Test func htmlSentAsPlainTextPreviewsAsText() {
        // Some senders label HTML as text/plain; its style code must not become the preview.
        let html = "<style type=\"text/css\"> html { height: 100%; } body { width: 100% !important; }</style><table><tr><td>Nieuwe zoekresultaten: 3 nieuwe advertenties</td></tr></table>"
        let part = IMAPTextPart(section: "1", isHTML: false, encoding: "7BIT", charset: "utf-8")
        #expect(part.preview(from: Array(html.utf8)) == "Nieuwe zoekresultaten: 3 nieuwe advertenties")

        // Cut off inside the style block: nothing to show yet, so it's read again as HTML, longer.
        let start = Array(html.utf8.prefix(40))
        let cut = part.preview(from: start)
        #expect(cut.isEmpty)
        #expect(part.againAsHTML(after: start, preview: cut)?.previewBytes == 6144)
        #expect(IMAPTextPart(section: "1", isHTML: false, encoding: nil, charset: nil).againAsHTML(after: Array("Hello".utf8), preview: "") == nil)
    }

    @Test func previewsSavedAsStyleCodeAreCleanedWhenRead() {
        #expect(HTMLText.cleanedPreview("<style type=\"text/css\"> html { height: 100%; width: 100%; margin: 0; padding: 0; } body { width: 100% !important; height: 10…") == "")
        #expect(HTMLText.cleanedPreview("Lunch on Friday? ------ See you") == "Lunch on Friday? See you")
        #expect(!HTMLText.looksLikeHTML("<3 thanks for lunch"))
        #expect(!HTMLText.looksLikeHTML("Use <b> for bold"))
        #expect(HTMLText.looksLikeHTML("  <!DOCTYPE html><html>"))
    }

    @Test func decodesACutOffBase64HTMLStart() {
        let html = "<html><head><style>p{}</style></head><body><p>Hi Kaan,</p><p>Dinner on Friday?</p></body></html>"
        var encoded = Array(Data(html.utf8).base64EncodedString(options: .lineLength76Characters).utf8)
        encoded.removeLast(3) // cut mid-group, as a partial fetch does
        let part = IMAPTextPart(section: "1", isHTML: true, encoding: "BASE64", charset: "utf-8")
        #expect(part.preview(from: encoded).hasPrefix("Hi Kaan, Dinner on Friday?"))
    }

    @Test func decodesQuotedPrintableInLatin1() {
        let part = IMAPTextPart(section: "1", isHTML: false, encoding: "quoted-printable", charset: "iso-8859-1")
        let preview = part.preview(from: Array("Caf=E9 om drie?\r\n> old quote".utf8))
        #expect(preview == "Café om drie?", "\(preview.debugDescription)")
    }
}

@Suite struct PreviewCleanupTests {
    @Test func dropsAStyleBlockCutOffByThePartialFetch() {
        let html = "<html><head><style>@media only screen and (max-width: 640px) { .wrap { width: 100% } "
        #expect(HTMLText.plain(html) == "")
        let withBody = "<html><head><style>p{}</style></head><body><p>Approved</p><div style=\"x"
        #expect(HTMLText.plain(withBody) == "Approved")
    }

    @Test func decodesEntitiesInPlainText() {
        let part = IMAPTextPart(section: "1", isHTML: false, encoding: nil, charset: "utf-8")
        #expect(part.preview(from: Array("De voor- en nadelen&nbsp;op een rij&#160;| &amp;nbsp; caf&#xE9;".utf8))
                == "De voor- en nadelen op een rij | &nbsp; café")
    }
}

@Suite struct SignInCodeNearbyTests {
    @Test func ignoresNumbersInLinks() {
        let text = "Er is een nieuwe app verbonden. Beveiligingsmeldingen\nPrivacyverklaring: https://go.microsoft.com/fwlink/?LinkId=521839"
        #expect(SignInCode.detect(subject: "Nieuwe apps verbonden met uw Microsoft-account", text: text) == nil)
    }

    @Test func needsACodeWordNearTheNumber() {
        #expect(SignInCode.detect(subject: "Security alert", text: "We noticed a sign-in from a new device. Reference 482913 in our records.") == nil)
        #expect(SignInCode.detect(subject: "Uw beveiligingscode", text: "Gebruik deze code: 551 902") == "551902")
    }
}

@Suite struct DomainLogoTests {
    @Test func freeMailHasNoCompanyLogo() {
        #expect(!DomainLogos.isCompanyDomain("gmail.com"))
        #expect(!DomainLogos.isCompanyDomain("outlook.com"))
        #expect(DomainLogos.isCompanyDomain("relevate.app"))
    }

    @Test func prefersTheTouchIconAndResolvesRelativeLinks() {
        let page = """
        <link rel="icon" href="/favicon-32.png" sizes="32x32">
        <link rel="icon" type="image/svg+xml" href="/icon.svg">
        <link rel='apple-touch-icon' href="images/touch.png">
        """
        let links = DomainLogos.iconLinks(in: page, base: URL(string: "https://www.example.com/nl/")!)
        #expect(links.map(\.absoluteString) == ["https://www.example.com/nl/images/touch.png", "https://www.example.com/favicon-32.png"])
    }

    @Test func providerFromTheServerForCustomDomains() {
        let account = MailAccount(label: "Work", address: EmailAddress(address: "kaan@relevate.app"),
                                  connection: .imap(incoming: ServerEndpoint(host: "outlook.office365.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.office365.com", port: 587, security: .startTLS)),
                                  auth: .password(username: "kaan@relevate.app"))
        #expect(ProviderCatalog.preset(for: account)?.id == "microsoft")
    }
}
