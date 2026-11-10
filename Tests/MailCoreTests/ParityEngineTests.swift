import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MailCore

@Suite struct ParityEngineTests {
    func thread(_ subject: String, from: String = "billing@power.example", snippet: String = "") -> MailThread {
        let message = MailMessage(id: UUID().uuidString, mailboxID: "INBOX", from: EmailAddress(address: from), subject: subject,
                                  date: Date(), snippet: snippet)
        return MailThread(id: message.id, messages: [message])
    }

    @Test func clearMailIsSortedByRules() {
        let groups = EmailGroup.starters
        #expect(EmailSorter.ruleGroup(for: thread("Your invoice for March"), groups: groups)?.name == groups[3].name)
        #expect(EmailSorter.ruleGroup(for: thread("Your order has shipped"), groups: groups)?.name == groups[5].name)
        #expect(EmailSorter.ruleGroup(for: thread("Boarding pass for AMS → LIS"), groups: groups)?.name == groups[6].name)
        #expect(EmailSorter.ruleGroup(for: thread("Lunch on Friday?", from: "noor@example.com"), groups: groups) == nil)
    }

    @Test func modelAnswersAreMatchedToGroups() {
        let groups = EmailGroup.starters
        #expect(MailIntelligence.matchGroup("\"Travel\".", in: groups)?.name == groups[6].name)
        #expect(MailIntelligence.matchGroup("travel", in: groups)?.name == groups[6].name)
        #expect(MailIntelligence.matchGroup("None", in: groups) == nil)
        #expect(MailIntelligence.matchGroup("Something else", in: groups) == nil)
    }

    @Test func signaturesAreMadeAndFound() {
        let made = SignatureTools.make(.init(name: "Lena Fischer", role: "Designer", company: "Northwind", phone: "+31 6 1234 5678", website: "northwind.example"))
        #expect(made.text == "Lena Fischer\nDesigner · Northwind\n+31 6 1234 5678 · northwind.example")
        #expect(made.html.contains("href=\"https://northwind.example\"") && made.html.contains("tel:+31612345678"))

        let signature = "Lena Fischer\nDesigner · Northwind"
        let sent = [
            "Hi Noor,\n\nSounds good.\n\nThanks,\n\(signature)",
            "Sure, Tuesday works.\n\n\(signature)\n\nOn Mon, Sam wrote:\n> hello",
            "Attached.\n\nBest,\n\(signature)",
            "One quick question about the budget.",
        ]
        #expect(SignatureTools.find(in: sent) == signature)
        #expect(SignatureTools.find(in: ["Hi", "Hello there\nbye"]) == nil)
    }

    @Test func picturesAreMadeSmaller() throws {
        // A 3000 × 2000 picture, made in memory.
        let width = 3000, height = 2000
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        CGImageDestinationFinalize(destination)
        let png = output as Data

        let small = try #require(ImageResizer.resized(png, maxPixels: 256))
        #expect(ImageResizer.pixelSize(small).map { max($0.width, $0.height) } == 256)
        let sending = ImageResizer.forSending(png, mimeType: "image/png")
        #expect(sending.mimeType == "image/jpeg")
        #expect(ImageResizer.pixelSize(sending.data).map { max($0.width, $0.height) } == ImageResizer.sendingLimit)
        #expect(ImageResizer.forSending(Data("text".utf8), mimeType: "text/plain").mimeType == "text/plain")
    }
}

@Suite struct SignInLinkTests {
    @Test func findsTheSignInButton() throws {
        let html = #"<p>Click below to sign in.</p><a href="https://kettle.example/unsubscribe">Unsubscribe</a> <a href="https://kettle.example/auth/magic?token=abc&amp;x=1">Sign in to Kettle</a>"#
        let found = try #require(SignInLink.detect(subject: "Your sign-in link", text: "Click below to sign in.", html: html))
        #expect(found.url.absoluteString == "https://kettle.example/auth/magic?token=abc&x=1")
        #expect(found.kind == .signIn)
    }

    @Test func confirmationLinksInPlainText() throws {
        let found = try #require(SignInLink.detect(subject: "Confirm your email", text: "Confirm your email: https://app.example/confirm/123", html: nil))
        #expect(found.kind == .confirm)
        #expect(found.url.path().hasPrefix("/confirm"))
    }

    @Test func ordinaryMailHasNone() {
        #expect(SignInLink.detect(subject: "Lunch?", text: "See https://maps.example/cafe", html: nil) == nil)
        #expect(SignInLink.detect(subject: "Sign in to see your order", text: "Only an unsubscribe link: https://shop.example/unsubscribe", html: nil) == nil)
    }
}

@Suite struct TrackerBlockerTests {
    @Test func pixelsAreRemovedAndNamed() {
        let html = #"<p>Hi</p><img src="https://example.list-manage.com/track/open.php?u=1" width="1" height="1"><img src="https://cdn.shop.example/hero.jpg" width="600"><img src="https://t.mail.example/x.gif" style="display:none">"#
        let result = TrackerBlocker.clean(html)
        #expect(!result.html.contains("list-manage"))
        #expect(!result.html.contains("x.gif"))
        #expect(result.html.contains("hero.jpg"))
        #expect(result.blocked.contains("list-manage.com"))
        #expect(result.blocked.count == 2)
    }

    @Test func linksGoStraightToWhereTheyPoint() {
        let tracked = "https://click.mail.example/ls/click?url=https%3A%2F%2Fshop.example%2Fsale%3Futm_source%3Dmail%26id%3D7"
        #expect(TrackerBlocker.cleanLink(tracked) == "https://shop.example/sale?id=7")
        #expect(TrackerBlocker.cleanLink("https://news.example/a?utm_campaign=x&page=2") == "https://news.example/a?page=2")
        #expect(TrackerBlocker.cleanLink("https://plain.example/a?b=1") == "https://plain.example/a?b=1")
    }

    @Test func sanitizerUsesItWhenAsked() {
        let html = #"<img src="https://sendgrid.net/wf/open?upn=1" width="1" height="1"><a href="https://site.example/?utm_source=x">Go</a>"#
        let blocked = HTMLSanitizer.sanitize(html, blockTrackers: true)
        #expect(blocked.blockedTrackers == ["sendgrid.net"])
        #expect(blocked.cleanedLinks == 1)
        #expect(!blocked.hasRemoteContent)
        #expect(HTMLSanitizer.sanitize(html).blockedTrackers.isEmpty)
    }
}
