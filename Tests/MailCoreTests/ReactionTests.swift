import Foundation
import Testing
@testable import MailCore

@Suite struct ReactionTests {
    static let me = EmailAddress(name: "Kaan Mol", address: "kaan@example.com")
    static let jane = EmailAddress(name: "Jolie, Jane", address: "jane@example.org")
    static let day = Date(timeIntervalSince1970: 1_780_000_000)

    static func mail(_ id: String, from: EmailAddress = jane, subject: String = "RE: Test msreactions", snippet: String = "",
                     inReplyTo: String? = "original@example.com", at offset: TimeInterval = 3600,
                     headers: [String: String] = [:]) -> MailMessage {
        MailMessage(id: id, mailboxID: "INBOX", messageID: "\(id)@example.org", inReplyTo: inReplyTo, from: from,
                    to: [me], subject: subject, date: day.addingTimeInterval(offset), snippet: snippet, listHeaders: headers)
    }

    static let original = MailMessage(id: "Sent/7", mailboxID: "Sent", messageID: "original@example.com", from: me, to: [jane],
                                      subject: "Test msreactions", date: day, snippet: "lorem ipsum dolor")

    // An Outlook fallback email as it arrives over IMAP (text part).
    static let outlookText = """
    [laugh]         Jolie, Jane reacted to your message:
    ________________________________
    From: Kaan Mol <kaan@example.com>
    Sent: Monday, July 8, 2024 7:19:12 AM
    To: Jolie, Jane <jane@example.org>
    Subject: Test msreactions

    lorem ipsum dolor
    """

    // MARK: Recognising

    @Test func readsOutlooksReactionEmail() throws {
        let reaction = try #require(MailReaction.detect(Self.mail("r1"), text: Self.outlookText))
        #expect(reaction.emoji == "😆")
        #expect(reaction.from.address == "jane@example.org")
        #expect(reaction.inReplyTo == "original@example.com")
    }

    @Test func readsItFromThePreviewAlone() {
        let preview = "[like] Jolie, Jane reacted to your message: ________________________________ From: Kaan Mol Sent: Monday"
        #expect(MailReaction.detect(Self.mail("r1"), text: preview)?.emoji == "👍")
        // And sorts it out of People.
        #expect(InboxSplit.classify(Self.mail("r1", snippet: preview)) == .updates)
    }

    @Test func readsTheReactionFromThePictureInTheFormattedVersion() {
        let html = #"<p><img src="cid:reaction" alt="heart" width="20"> Jolie, Jane reacted to your message:</p>"#
        let reaction = MailReaction.detect(Self.mail("r1"), text: "Jolie, Jane reacted to your message:", html: html)
        #expect(reaction?.emoji == "❤️")
    }

    @Test func knowsOtherLanguages() {
        for line in ["[like] Jolie, Jane hat auf Ihre Nachricht reagiert:", "[like] Jolie, Jane heeft gereageerd op uw bericht:",
                     "[like] Jolie, Jane a réagi à votre message :", "[like] Jolie, Jane reaccionó a su mensaje:"] {
            #expect(MailReaction.detect(Self.mail("r1"), text: line)?.emoji == "👍", "\(line)")
        }
    }

    @Test func readsTheShapeInALanguageItDoesntKnow() {
        let swedish = MailReaction.detect(Self.mail("r1", subject: "SV: Test"), text: "👍 Jolie, Jane reagerade på ditt meddelande:\n___")
        #expect(swedish?.emoji == "👍")
    }

    @Test func leavesOrdinaryMailAlone() {
        let lines = [
            "Thanks Jane, see my notes below:",
            "[EXTERNAL] Jolie, Jane: please review the contract",
            "👍 Jolie, Jane: sounds good to me",
            "Did you see that Bob reacted to your message about the budget?",
            "Hi Kaan,\n\nJane reacted to your message in the meeting.",
        ]
        for line in lines {
            #expect(MailReaction.detect(Self.mail("m1"), text: line) == nil, "\(line)")
        }
    }

    @Test func aReplyThatIsOnlyAnEmojiIsAReaction() {
        #expect(MailReaction.detect(Self.mail("r1"), text: "🎉")?.emoji == "🎉")
        #expect(MailReaction.detect(Self.mail("r1"), text: "👍\n\nSent from my iPhone")?.emoji == "👍")
        #expect(MailReaction.detect(Self.mail("r1"), text: "❤️\n\nOn Tue, 10 Nov 2026, Kaan Mol wrote:\n> lorem")?.emoji == "❤️")
        // Words after it, or not a reply at all: an ordinary message.
        #expect(MailReaction.detect(Self.mail("r1"), text: "👍 on it, will do tomorrow") == nil)
        #expect(MailReaction.detect(Self.mail("n1", subject: "Party", inReplyTo: nil), text: "🎉") == nil)
        #expect(MailReaction.detect(Self.mail("r1"), text: "2") == nil)
    }

    @Test func sortingABigInboxOfRepliesStaysQuick() {
        let replies = (0..<2_000).map {
            Self.mail("m\($0)", subject: "Re: Plans \($0)", snippet: "Sounds good, see you on Tuesday. Kaan wrote: > lorem ipsum")
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure { for message in replies { _ = InboxSplit.classify(message) } }
        #expect(elapsed < .milliseconds(40), "\(elapsed)")
    }

    // MARK: Placing

    @Test func putsAReactionOnTheMessageItAnswers() {
        let reaction = Self.mail("INBOX/9", snippet: "[like] Jolie, Jane reacted to your message:")
        let layout = MailReaction.layout([Self.original, reaction]) { MailReaction.detect($0, text: $0.snippet) }
        #expect(layout.messages.map(\.id) == ["Sent/7"])
        #expect(layout.reactions["Sent/7"]?.map(\.emoji) == ["👍"])
    }

    @Test func keepsOnlyEachPersonsLatestReaction() {
        let first = Self.mail("INBOX/9", snippet: "[like] Jolie, Jane reacted to your message:", at: 60)
        let second = Self.mail("INBOX/10", snippet: "[heart] Jolie, Jane reacted to your message:", at: 120)
        let layout = MailReaction.layout([Self.original, first, second]) { MailReaction.detect($0, text: $0.snippet) }
        #expect(layout.messages.count == 1)
        #expect(layout.reactions["Sent/7"]?.map(\.emoji) == ["❤️"])
    }

    @Test func aReactionWithoutItsMessageStays() {
        let reaction = Self.mail("INBOX/9", snippet: "[like] Jolie, Jane reacted to your message:")
        let layout = MailReaction.layout([reaction]) { MailReaction.detect($0, text: $0.snippet) }
        #expect(layout.messages.map(\.id) == ["INBOX/9"])
        #expect(layout.reactions.isEmpty)
    }

    @Test func groupsByEmoji() {
        let a = MailReaction(emoji: "👍", from: Self.jane, date: Self.day, messageID: "1")
        let b = MailReaction(emoji: "👍", from: Self.me, date: Self.day, messageID: "2")
        let c = MailReaction(emoji: nil, from: Self.me, date: Self.day, messageID: "3")
        let groups = MailReaction.grouped([a, b, c])
        #expect(groups.map(\.emoji) == ["👍", ""])
        #expect(groups[0].people.count == 2)
    }

    // MARK: Reacting

    @Test func reactsOnlyWhereItMakesSense() {
        let me: Set<String> = ["kaan@example.com"]
        #expect(MailReaction.canReact(to: Self.mail("m1"), me: me))
        #expect(!MailReaction.canReact(to: Self.original, me: me))
        #expect(!MailReaction.canReact(to: Self.mail("m1", headers: ["x-ms-reactions": "disallow"]), me: me))
        #expect(!MailReaction.canReact(to: Self.mail("m1", headers: ["list-id": "<news.example>"]), me: me))
    }

    @Test func sendsAReactionInOutlooksShapeAndReadsItBack() throws {
        let message = Self.mail("INBOX/3", subject: "Plans", inReplyTo: nil)
        for language in ["en", "de", "nl", "ja", "pt-BR", "zh-Hans", "fr-CA", "tr", "zh-Hant", "pl", "sv"] {
            let draft = MailReaction.reply("👍", to: message, originalText: "See you at 3?", from: Self.me, language: language,
                                           timeZone: TimeZone(identifier: "UTC")!)
            #expect(draft.to == [Self.jane])
            #expect(draft.cc.isEmpty)
            #expect(draft.subject == "RE: Plans")
            #expect(draft.inReplyTo == message.messageID)
            #expect(draft.text.hasPrefix("👍 ") && draft.text.contains("Kaan Mol"))
            #expect(draft.text.contains("See you at 3?"))
            // What Margin sends, Margin (and the person's own Margin) reads as a reaction.
            let sent = MailMessage(id: "Sent/1", mailboxID: "Sent", messageID: "<r@example.com>", inReplyTo: draft.inReplyTo,
                                   from: Self.me, subject: draft.subject, date: Self.day, snippet: "")
            #expect(MailReaction.detect(sent, text: draft.text)?.emoji == "👍", "\(language)")
        }
        let english = MailReaction.reply("🎉", to: message, originalText: "x", from: Self.me, language: "en")
        #expect(english.text.hasPrefix("🎉 Kaan Mol reacted to your message:\n________________________________\nFrom: "))
        #expect(MailReaction.reply("🎉", to: message, originalText: "x", from: Self.me, language: "zh-Hant").text.contains("回應了你的郵件"))
    }

    @Test func keepsTheSubjectAsWritten() {
        #expect(MailReaction.originalSubject("RE: AW: Plans for Q3") == "Plans for Q3")
        #expect(MailReaction.originalSubject("Plans") == "Plans")
        #expect(MailReaction.reply("👍", to: Self.mail("m", subject: "Re: Plans"), originalText: "", from: Self.me, language: "en").subject == "Re: Plans")
    }

    // MARK: Real shapes

    /// The shape of a real Outlook reaction email (names changed): multipart/related around
    /// multipart/alternative, Windows-1252 text, and HTML with the reaction as a picture.
    static let outlookEML = """
    From: Jane Jolie <jane@example.org>\r
    To: Kaan Mol <kaan@example.com>\r
    Subject: RE: Plans for Q3\r
    Thread-Topic: Plans for Q3\r
    Date: Mon, 6 Jul 2026 08:12:54 +0000\r
    Message-ID:\r
    \t<reaction-1@example.prod.outlook.com>\r
    References:\r
    \t<original-1@example.com>\r
    In-Reply-To:\r
    \t<original-1@example.com>\r
    Content-Language: en-US\r
    X-MS-Has-Attach: yes\r
    Content-Type: multipart/related;\r
    \tboundary="_008_REL_";\r
    \ttype="multipart/alternative"\r
    MIME-Version: 1.0\r
    \r
    --_008_REL_\r
    Content-Type: multipart/alternative;\r
    \tboundary="_000_ALT_"\r
    \r
    --_000_ALT_\r
    Content-Type: text/plain; charset="Windows-1252"\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    [like]  Jane Jolie reacted to your message:\r
    ________________________________\r
    From: Kaan Mol <kaan@example.com>\r
    Sent: Monday, 06 July 2026 08:01:39\r
    To: Jane Jolie <jane@example.org>\r
    Subject: Plans for Q3\r
    \r
    Caf=E9 at three?\r
    \r
    --_000_ALT_\r
    Content-Type: text/html; charset="Windows-1252"\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    <html><body><table style=3D"background:#EFF6FC"><tr><td><img alt=3D"like" src=3D"=\r
    https://outlook-1.cdn.office.net/assets/reaction/like.png" style=3D"height:25px"=\r
    ></td><td><span style=3D"font-weight:bold">Jane Jolie</span> <span>reacted to y=\r
    our message:</span></td></tr></table><hr><div id=3D"divRplyFwdMsg"><b>From:</b>=\r
     Kaan Mol</div><p>Caf=E9 at three?</p></body></html>\r
    \r
    --_000_ALT_--\r
    \r
    --_008_REL_--\r
    """

    static func parsed(_ eml: String) -> (MailMessage, MessageBody) {
        let mime = MIMEMessage.parse(Array(eml.utf8))
        let message = MailMessage(id: "INBOX/1", mailboxID: "INBOX", messageID: "reaction-1@example.prod.outlook.com",
                                  inReplyTo: "original-1@example.com", from: EmailAddress(name: "Jane Jolie", address: "jane@example.org"),
                                  subject: "RE: Plans for Q3", date: day)
        return (message, mime.body)
    }

    @Test func readsARealOutlookReactionEmail() {
        let (message, body) = Self.parsed(Self.outlookEML)
        #expect(MailReaction.detect(message, text: body.text, html: body.html)?.emoji == "👍")
        // Only the formatted version: the reaction comes from the picture.
        #expect(MailReaction.detect(message, text: HTMLText.plain(body.html ?? ""), html: body.html)?.emoji == "👍")
    }

    @Test func readsThePictureLinkFormAndOutlooksNames() {
        let line = "<https://outlook-1.cdn.office.net/assets/reaction/surprised.png> \tJane Jolie reacted to your message: \t"
        #expect(MailReaction.detect(Self.mail("r1"), text: line)?.emoji == "😲")
        #expect(MailReaction.Kind.surprised.emoji == "😲")
    }

    @Test func aTakenBackReactionTakesItsReactionAway() {
        let like = Self.mail("INBOX/9", snippet: "[like] Jolie, Jane reacted to your message:", at: 60)
        var removal = Self.mail("INBOX/10", at: 120)
        removal.snippet = "Jolie, Jane reacted to your message:"
        let html = #"<td><img alt="0" src=""></td><td><span>Jolie, Jane</span> <span>reacted to your message:</span></td>"#
        let detect: (MailMessage) -> MailReaction? = { m in
            MailReaction.detect(m, text: m.snippet, html: m.id == "INBOX/10" ? html : nil)
        }
        #expect(detect(removal)?.isRemoval == true)
        let layout = MailReaction.layout([Self.original, like, removal], reaction: detect)
        #expect(layout.messages.map(\.id) == ["Sent/7"])
        #expect(layout.reactions["Sent/7"] == nil)
    }

    @Test func readsGmailsReactionPart() {
        #expect(MailReaction.gmailEmoji(Data(#"{"version":1,"emoji":"🎉"}"#.utf8)) == "🎉")
        #expect(MailReaction.gmailEmoji(Data(#"{"version":"1","emoji":"🎉"}"#.utf8)) == nil)
        #expect(MailReaction.gmailEmoji(Data(#"{"version":1,"emoji":"🎉🎉"}"#.utf8)) == nil)
        #expect(MailReaction.gmailEmoji(Data(#"{"version":1,"emoji":"ok"}"#.utf8)) == nil)
        let gmail = MailReaction.detect(Self.mail("r1", subject: "Re: Plans"), text: "Jane reacted via Gmail", gmail: "🎉")
        #expect(gmail?.emoji == "🎉")
    }

    @Test func sendsGmailsPartBetweenTheTextAndTheHTML() throws {
        let message = Self.mail("INBOX/3", subject: "Plans", inReplyTo: nil)
        var draft = MailReaction.reply("❤️", to: message, originalText: "See you at 3?", from: Self.me, language: "en")
        #expect(draft.reaction == "❤️")
        draft.html = "<p>❤️ Kaan Mol reacted to your message:</p>"
        let raw = String(decoding: MessageBuilder.build(draft), as: UTF8.self)
        let text = try #require(raw.range(of: "Content-Type: text/plain"))
        let part = try #require(raw.range(of: "Content-Type: \(MailReaction.gmailType)"))
        let html = try #require(raw.range(of: "Content-Type: text/html"))
        #expect(text.lowerBound < part.lowerBound && part.lowerBound < html.lowerBound)
        #expect(raw.contains("In-Reply-To: <INBOX/3@example.org>"))
        // And it reads back: as a Gmail reaction, and as Outlook-style text.
        let body = MIMEMessage.parse(MessageBuilder.build(draft)).body
        #expect(body.reaction == "❤️")
        #expect(body.text.hasPrefix("❤️ Kaan Mol reacted to your message:"))
    }

    @Test func leavesGmailsPartOutWhereGmailWouldnt() {
        // Not among the recipients (Bcc or a list), or more than 20 of them.
        let bcc = MailMessage(id: "m", mailboxID: "INBOX", messageID: "m@x", from: Self.jane, to: [EmailAddress(address: "team@example.org")],
                              subject: "Plans", date: Self.day)
        #expect(MailReaction.reply("👍", to: bcc, originalText: "", from: Self.me, language: "en").reaction == nil)
        var crowd = Self.mail("m2")
        crowd.cc = (0..<21).map { EmailAddress(address: "p\($0)@example.org") }
        #expect(MailReaction.reply("👍", to: crowd, originalText: "", from: Self.me, language: "en").reaction == nil)
    }
}
