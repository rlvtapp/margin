import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct MarginNoteTests {
    @Test func notesSayWhyAConversationMatters() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let threads = model.inboxThreads(nil)
        // The sample's sign-in code gets "code"; a newsletter gets nothing.
        let kettle = try #require(threads.first { $0.subject.contains("sign-in code") })
        #expect(model.marginNote(for: kettle)?.kind == .code)
        let weekly = try #require(threads.first { $0.subject.contains("Issue 212") })
        #expect(model.marginNote(for: weekly) == nil)
        // A bill still to pay gets "bill"; a card payment already made, filed with the bills, doesn't.
        let bills = model.emailGroups.first { $0.name == EmailGroup.starters[3].name }
        let invoice = try #require(threads.first { $0.subject.contains("Invoice question") })
        // The assistant read that it asks to pay; the card payment it read as paid.
        MailVerdicts.shared.set([MailVerdicts.key(invoice.latest): MailVerdict(automated: false, needsReply: false, asksToPay: true)])
        model.move(invoice, toGroup: bills)
        #expect(model.marginNote(for: invoice)?.text == "bill")
        let bank = try #require(threads.first { $0.subject.contains("Card payment") })
        model.move(bank, toGroup: bills)
        #expect(model.marginNote(for: bank) == nil)
        #expect(model.needYouCount >= 2)
        #expect(!model.homeDate.isEmpty)
    }
}

@Suite struct PlainTextLinksTests {
    @Test func shortensLongLinksButKeepsWhereTheyGo() {
        let long = "https://outlook.office365.com/owa/sct-15-20-9412-4-msonline-outlook-583ad.templateTenant/?itemid=AQMkADAw&exvsurl=1&path=/calendar/item"
        let text = PlainTextLinks.attributed("Open: \(long) please. See https://margin.relevate.app too.")
        let plain = String(text.characters)
        #expect(plain.contains("outlook.office365.com/owa/…"))
        #expect(plain.contains("https://margin.relevate.app"))
        #expect(!plain.contains("itemid"))
        #expect(text.runs.contains { $0.link?.absoluteString == long })
    }
}

@MainActor @Suite struct VerdictTests {
    /// What the assistant read moves a conversation to Other and gives it its notes; nothing
    /// else does.
    @Test func verdictsMoveMailAndGiveNotes() async throws {
        let model = MailModel(environment: .preview())
        let account = model.accounts[0]
        let message = MailMessage(id: "INBOX/v1", mailboxID: "INBOX", messageID: "<\(UUID().uuidString)@service.example>",
                                  from: EmailAddress(name: "Service", address: "noreply@service.example"), to: [account.address],
                                  subject: "Agreement signed", date: Date(), snippet: "You have signed the agreement.")
        let thread = MailModel.tag(MailThread(id: "v1", messages: [message]), account: account.id)
        model.setInbox([thread], for: account.id)
        #expect(model.inboxThreads(nil).first?.split == .people)
        model.record([thread.id: MailVerdict(automated: true, needsReply: false, asksToPay: false)], for: [thread])
        #expect(model.inboxThreads(nil).first?.split == .updates)
        #expect(model.marginNote(for: thread)?.kind != .reply)
    }
}
