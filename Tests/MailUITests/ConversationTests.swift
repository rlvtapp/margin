import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct ConversationTests {
    @Test func addsYourRepliesFromSentButNothingUnrelated() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = model.accounts[0]
        let them = EmailAddress(name: "Noor", address: "noor@example.com")
        let first = MailMessage(id: "INBOX/1", mailboxID: "INBOX", messageID: "a@x", from: them, to: [account.address],
                                subject: "Dinner", date: Date(timeIntervalSince1970: 100))
        let third = MailMessage(id: "INBOX/2", mailboxID: "INBOX", messageID: "c@x", inReplyTo: "b@x", references: ["a@x", "b@x"],
                                from: them, to: [account.address], subject: "Re: Dinner", date: Date(timeIntervalSince1970: 300))
        let inbox = MailThread(id: "t", messages: [first, third], accountID: account.id)
        let myReply = MailMessage(id: "Sent/9", mailboxID: "Sent", messageID: "b@x", inReplyTo: "a@x", references: ["a@x"],
                                  from: account.address, to: [them], subject: "Re: Dinner", date: Date(timeIntervalSince1970: 200))
        let unrelated = MailMessage(id: "Sent/10", mailboxID: "Sent", messageID: "z@x", from: account.address, to: [them],
                                    subject: "Dinner", date: Date(timeIntervalSince1970: 250))
        model.sentMail[account.id] = [unrelated, myReply]

        let both = model.conversation(inbox)
        #expect(both.messages.map(\.id) == ["INBOX/1", "Sent/9", "INBOX/2"])
        #expect(both.id == inbox.id)
        #expect(inbox.messages.count == 2)
    }
}
