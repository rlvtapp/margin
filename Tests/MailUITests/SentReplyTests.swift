import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct SentReplyTests {
    /// A reply sent from Margin shows in its conversation straight away, before the server's
    /// Sent folder is read again: both sides of a conversation, also one with yourself.
    @Test func justSentReplyJoinsItsConversation() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = try #require(model.inboxThreads(nil).first { $0.latest.messageID != nil && $0.accountID != nil })
        let account = try #require(model.account(thread.accountID))
        let before = model.conversation(thread).messages.count

        let reply = Draft.reply(to: thread, from: account.address, all: false)
        model.noteSent(reply, account: account)

        let after = model.conversation(thread)
        #expect(after.messages.count == before + 1)
        #expect(after.messages.last?.from.address == account.address.address)
        #expect(after.messages.last?.body != nil)
    }

    /// Something sent that isn't a reply to this conversation stays out of it.
    @Test func unrelatedSentMailStaysOut() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = try #require(model.inboxThreads(nil).first { $0.latest.messageID != nil && $0.accountID != nil })
        let account = try #require(model.account(thread.accountID))
        let before = model.conversation(thread).messages.count
        model.noteSent(Draft(from: account.address, to: [EmailAddress(address: "someone@example.com")], subject: "Elsewhere", text: "Hi"), account: account)
        #expect(model.conversation(thread).messages.count == before)
    }

    /// A reply sent from another app sits only in Sent; the conversation no longer owes one.
    @Test func replyInSentClearsReplyOwed() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let owed = try #require(model.inboxThreads(nil).first { model.owesReply($0) && $0.latest.messageID != nil })
        let account = try #require(model.account(owed.accountID))
        model.noteSent(Draft.reply(to: owed, from: account.address, all: false), account: account)
        #expect(!model.owesReply(owed))
    }

    /// Bcc recipients go into the message being sent, and a message to Bcc alone is allowed.
    @Test func bccRecipientsAreSent() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        var state = ComposeState(account: account)
        state.bcc = "Noor <noor@example.com>, sam@example.com"
        state.draft.subject = "Quiet copy"
        let draft = try state.validated()
        #expect(draft.bcc.map(\.address) == ["noor@example.com", "sam@example.com"])
        #expect(draft.to.isEmpty)
        #expect(draft.recipients.count == 2)
        // And it never ends up in the message itself.
        let raw = String(decoding: MessageBuilder.build(draft), as: UTF8.self)
        #expect(!raw.contains("noor@example.com"))
    }
}
