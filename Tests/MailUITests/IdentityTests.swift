import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct IdentityTests {
    func account() -> MailAccount {
        var account = MailAccount.sample
        account.signature = "Alex"
        account.aliases = [EmailAddress(name: "Northwind Sales", address: "sales@northwind.example")]
        account.moreSignatures = [NamedSignature(name: "Short", text: "– A")]
        account.replySignature = "Short"
        return account
    }

    @Test func repliesComeFromTheAliasTheMailWasSentTo() {
        let account = account()
        let message = MailMessage(id: "1", mailboxID: "INBOX", from: EmailAddress(address: "buyer@shop.example"),
                                  to: [EmailAddress(address: "sales@northwind.example")], subject: "Quote", date: Date())
        let thread = MailThread(id: "1", messages: [message])
        #expect(account.replyAddress(for: thread).address == "sales@northwind.example")
    }

    @Test func repliesUseTheReplySignatureAndItCanBeSwapped() {
        let account = account()
        var reply = ComposeState(account: account, isReply: true)
        #expect(reply.draft.text == "\n\n– A")
        reply.draft.text = "Thanks!" + reply.draft.text
        reply.use(signature: "Alex")
        #expect(reply.draft.text == "Thanks!\n\nAlex")
        reply.use(signature: nil)
        #expect(reply.draft.text == "Thanks!")
        let fresh = ComposeState(account: account)
        #expect(fresh.draft.text == "\n\nAlex")
    }
}
