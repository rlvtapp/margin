import Foundation
import Testing
@testable import MailCore

@Suite struct TriageTests {
    let maya = EmailAddress(name: "Maya", address: "maya@studio.example")
    let me = EmailAddress(address: "me@example.com")

    func message(_ id: String, _ subject: String, from: EmailAddress, minutes: Double, messageID: String? = nil,
                 inReplyTo: String? = nil, headers: [String: String] = [:]) -> MailMessage {
        MailMessage(id: id, mailboxID: "INBOX", messageID: messageID, inReplyTo: inReplyTo, from: from, to: [me],
                    subject: subject, date: Date(timeIntervalSince1970: minutes * 60), listHeaders: headers)
    }

    @Test func threadsByHeadersThenSubject() {
        let messages = [
            message("1", "Plan", from: maya, minutes: 1, messageID: "a"),
            message("2", "Re: Plan", from: me, minutes: 2, messageID: "b", inReplyTo: "a"),
            // Parent not fetched: joins by subject because it's a reply.
            message("3", "AW: Re: plan", from: maya, minutes: 3, messageID: "c", inReplyTo: "zzz"),
            // Same subject, but a fresh message: its own thread.
            message("4", "Plan", from: maya, minutes: 4, messageID: "d"),
            message("5", "Lunch", from: maya, minutes: 5, messageID: "e"),
        ]
        let threads = Threader.threads(from: messages).sorted { $0.messages.count > $1.messages.count }
        #expect(threads.count == 3)
        #expect(threads[0].messages.map(\.id) == ["1", "2", "3"])
        #expect(Subject.normalized("Re: AW: Fwd: Hello") == "hello")
        #expect(Subject.normalized("RE[2]: Hello") == "hello")
    }

    @Test func splitsTheInbox() {
        #expect(InboxSplit.classify(message("1", "Hi", from: maya, minutes: 1)) == .people)
        #expect(InboxSplit.classify(message("2", "Issue 3", from: maya, minutes: 1, headers: ["list-unsubscribe": "<mailto:x>"])) == .newsletters)
        #expect(InboxSplit.classify(message("3", "Code", from: EmailAddress(address: "no-reply@bank.example"), minutes: 1)) == .updates)
        #expect(InboxSplit.classify(message("4", "Build", from: maya, minutes: 1, headers: ["auto-submitted": "auto-generated"])) == .updates)
        #expect(InboxSplit.classify(message("5", "Thanks", from: EmailAddress(address: "support@shop.example"), minutes: 1)) == .people)
    }

    @Test func searches() {
        var starred = message("1", "Launch plan", from: maya, minutes: 1)
        starred.flags = [.flagged, .seen]
        starred.snippet = "The press day moves to the 12th"
        let thread = MailThread(id: "1", messages: [starred])

        #expect(SearchQuery("from:maya is:starred").matches(thread))
        #expect(SearchQuery("\"press day\"").matches(thread))
        #expect(!SearchQuery("is:unread").matches(thread))
        #expect(!SearchQuery("from:sam").matches(thread))
        #expect(SearchQuery("subject:launch in:people").matches(thread))
        #expect(SearchQuery("").isEmpty)
    }

    @Test func buildsReplies() {
        let first = message("1", "Plan", from: maya, minutes: 1, messageID: "a")
        let mine = MailMessage(id: "2", mailboxID: "INBOX", messageID: "b", inReplyTo: "a", references: ["a"], from: me,
                               to: [maya], subject: "Re: Plan", date: Date(timeIntervalSince1970: 120))
        let draft = Draft.reply(to: MailThread(id: "1", messages: [first, mine]), from: me)
        #expect(draft.to == [maya])
        #expect(draft.subject == "Re: Plan")
        #expect(draft.inReplyTo == "a")
    }

    @Test func sampleAccountWorksOffline() async throws {
        let provider = SampleProvider()
        let inbox = try #require(try await provider.mailboxes().first { $0.role == .inbox })
        let threads = try await provider.threads(in: inbox, limit: 50)
        #expect(threads.count > 8)
        #expect(Set(threads.map(\.split)) == Set(InboxSplit.allCases))
        try await provider.perform(.done, on: [threads[0]])
        #expect(try await provider.threads(in: inbox, limit: 50).count == threads.count - 1)
    }

    @Test func catalogCoversTheBigProviders() {
        for domain in ["gmail.com", "outlook.com", "icloud.com", "yahoo.com", "fastmail.com", "proton.me"] {
            #expect(ProviderCatalog.preset(forDomain: domain) != nil, "\(domain)")
        }
        let xml = """
        <clientConfig version="1.1"><emailProvider id="x">
        <incomingServer type="pop3"><hostname>pop.x.example</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
        <incomingServer type="imap"><hostname>imap.x.example</hostname><port>993</port><socketType>SSL</socketType></incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.x.example</hostname><port>587</port><socketType>STARTTLS</socketType></outgoingServer>
        </emailProvider></clientConfig>
        """
        #expect(AutoConfigXML.parse(Data(xml.utf8)) == .imap(
            incoming: ServerEndpoint(host: "imap.x.example", port: 993, security: .tls),
            outgoing: ServerEndpoint(host: "smtp.x.example", port: 587, security: .startTLS)
        ))
    }
}

@Suite struct BulkMailSortingTests {
    private func mail(from address: String, headers: [String: String] = [:]) -> MailMessage {
        MailMessage(id: "1", mailboxID: "INBOX", from: EmailAddress(address: address), to: [], subject: "Hi",
                    date: Date(), snippet: "", listHeaders: headers)
    }

    @Test func bulkSendingHeadersAreNotPeople() {
        #expect(InboxSplit.classify(mail(from: "hello@shop.example", headers: ["feedback-id": "123:campaign:esp"])) == .updates)
        #expect(InboxSplit.classify(mail(from: "anna@shop.example")) == .people)
    }

    @Test func marketingAddressesAreNewsletters() {
        #expect(InboxSplit.classify(mail(from: "nieuwsbrief@shop.example")) == .newsletters)
    }

    @Test func seesThroughHideMyEmail() {
        let relayed = "info_at_mail_shop_nl_2xbn7dncjb_0ea31c7b@privaterelay.appleid.com"
        #expect(InboxSplit.senderLocalPart(EmailAddress(address: relayed)) == "info")
        #expect(InboxSplit.classify(mail(from: "news_at_shop_nl_abc@privaterelay.appleid.com")) == .newsletters)
    }
}

@Suite struct CorrespondentsTests {
    @Test func listsEveryoneYouWroteTo() async {
        let cache = MailCache(url: nil)
        let account = UUID()
        let sent = MailMessage(id: "s1", mailboxID: "Sent", from: EmailAddress(address: "Me@Example.com"),
                               to: [EmailAddress(address: "Anna@Friends.example")], cc: [EmailAddress(address: "bo@friends.example")],
                               subject: "Dinner", date: Date())
        let received = MailMessage(id: "r1", mailboxID: "INBOX", from: EmailAddress(address: "promo@shop.example"),
                                   to: [EmailAddress(address: "me@example.com")], subject: "Sale", date: Date())
        await cache.saveThreads([MailThread(id: "t1", messages: [sent]), MailThread(id: "t2", messages: [received])], account: account, mailbox: "Sent")
        let people = await cache.correspondents(of: ["me@example.com"])
        #expect(people == ["anna@friends.example", "bo@friends.example"])
    }
}

@Suite struct ThreadingBySubjectTests {
    private func mail(_ id: String, _ subject: String, from: String, to: String = "me@example.com", minutes: Double,
                      inReplyTo: String? = nil, headers: [String: String] = [:]) -> MailMessage {
        MailMessage(id: id, mailboxID: "INBOX", messageID: "\(id)@x", inReplyTo: inReplyTo, from: EmailAddress(address: from),
                    to: [EmailAddress(address: to)], subject: subject, date: Date(timeIntervalSince1970: minutes * 60), listHeaders: headers)
    }

    @Test func repeatedNoticesStaySeparate() {
        let threads = Threader.threads(from: (1...3).map {
            mail("p\($0)", "$5.00 payment was unsuccessful again", from: "failed-payments@billing.example", minutes: Double($0))
        })
        #expect(threads.count == 3)
    }

    @Test func aReplyJoinsTheConversationItsPeopleWereIn() {
        let threads = Threader.threads(from: [
            mail("1", "Hey", from: "hey@test.example", minutes: 1),
            mail("2", "Hey", from: "inbox@kaan.example", minutes: 2),
            mail("3", "Re: Hey", from: "friend@example.com", to: "inbox@kaan.example", minutes: 3, inReplyTo: "unknown@x"),
        ])
        let reply = threads.first { $0.messages.contains { $0.id == "3" } }
        #expect(reply?.messages.map(\.id) == ["2", "3"])
    }
}

@Suite struct MeetingNoticeTests {
    let outlook = """
    Microsoft Outlook Web Access: https://outlook.office365.com/owa/sct-15/?itemid=AQMkADAw%3D%3D&exvsurl=1&path=/calendar/item

    To receive meeting invitations as .iCalendar attachments instead of Outlook Web App links, go to https://outlook.office365.com/owa/sct-15/?path=/options/popandimap and select Send meeting invitations in iCalendar format.
    """

    @Test func readsAnOutlookAnswer() throws {
        let notice = try #require(MeetingNotice.detect(subject: "Declined: Second-round interview.", text: outlook))
        #expect(notice.kind == .declined)
        #expect(notice.title == "Second-round interview")
        #expect(notice.link?.absoluteString.contains("path=/calendar/item") == true)
        #expect(MeetingNotice.detect(subject: "Afgewezen: Kennismaking", text: "")?.kind == .declined)
        #expect(MeetingNotice.detect(subject: "Tentatively accepted: Standup", text: "")?.kind == .tentative)
        #expect(MeetingNotice.detect(subject: "Re: Lunch", text: "") == nil)
    }

    @Test func noticesAreUpdatesAndNeverWaitForAReply() {
        let me = EmailAddress(address: "kaan@relevate.app")
        let notice = MailMessage(id: "1", mailboxID: "Sent", messageID: "n@x", from: me, to: [EmailAddress(address: "jo@x.example")],
                                 subject: "Declined: Second-round interview.", date: Date(timeIntervalSinceNow: -5 * 86_400))
        #expect(InboxSplit.classify(notice) == .updates)
        let waiting = FollowUp.waiting(sent: [MailThread(id: "t", messages: [notice])], inbox: [], me: ["kaan@relevate.app"], olderThan: 86_400)
        #expect(waiting.isEmpty)
    }
}
