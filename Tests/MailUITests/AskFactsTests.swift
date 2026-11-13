import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AskFactsTests {
    /// With nothing owed, the assistant is told so in words, instead of the heading going missing.
    @Test func emptyHeadingsSayNone() throws {
        let environment = MailEnvironment.preview()
        let account = MailAccount(label: "Work", address: EmailAddress(address: "me@example.com"),
                                  connection: .imap(incoming: ServerEndpoint(host: "imap.example.com", port: 993, security: .tls),
                                                    outgoing: ServerEndpoint(host: "smtp.example.com", port: 465, security: .tls)),
                                  auth: .password(username: "me@example.com"))
        try environment.accounts.save([account])
        let facts = MailModel(environment: environment).askFacts()
        #expect(facts.contains("Mail that needs a reply: none."))
        #expect(facts.contains("Bills not opened yet: none."))
        #expect(facts.contains("Sent mail still waiting for an answer: none."))
    }

    /// "What needs a reply from me?" has no words worth searching mail for; a name or a topic does.
    @Test func questionWordsAreNotSearched() {
        #expect(MailModel.searchTerms(in: "What needs a reply from me?").isEmpty)
        #expect(MailModel.searchTerms(in: "Did Sam reply about the invoice?") == "Sam invoice")
    }

    /// One account failing leaves the others' fresh mail in place.
    @Test func oneFailingAccountDoesNotHoldTheOthersBack() async throws {
        let model = MailModel(environment: .preview())
        let accounts = model.accounts
        try #require(accounts.count >= 2)
        let message = MailMessage(id: "m1", mailboxID: "INBOX", from: EmailAddress(address: "sam@example.com"),
                                  to: [accounts[1].address], subject: "Fresh", date: Date())
        let inbox = Mailbox(id: "INBOX", name: "Inbox", role: .inbox)
        await model.apply(.init(id: accounts[0].id, error: "Sign-in was refused.", refused: true))
        await model.apply(.init(id: accounts[1].id, mailboxes: [inbox], threads: [MailThread(id: "t1", messages: [message])]))
        #expect(model.needsSignIn(accounts[0].id))
        #expect(model.loadErrors[accounts[1].id] == nil)
        #expect(model.inboxes[accounts[1].id]?.map(\.subject) == ["Fresh"])
    }
}

@MainActor @Suite struct UnreachableAccountTests {
    /// A dropped connection is a passing thing, not an account problem: it's tried again by
    /// itself, sooner than the regular refresh and a little later each time.
    @Test func anUnreachableAccountIsRetriedWithGrowingPauses() async throws {
        let model = MailModel(environment: .preview())
        let account = try #require(model.accounts.first)
        #expect(MailModel.isNetworkFailure(MailError.connectionFailed("Socket is not connected")))
        #expect(MailModel.isNetworkFailure(MailError.connectionClosed))
        #expect(MailModel.isNetworkFailure(MailError.timedOut))
        #expect(!MailModel.isNetworkFailure(MailError.authenticationFailed("no")))
        #expect([1, 2, 3, 4, 9].map(MailModel.retryDelay(after:)) == [20, 40, 80, 160, 180])

        let before = Date()
        await model.apply(.init(id: account.id, error: "Socket is not connected", offline: true))
        #expect(model.isUnreachable(account.id))
        #expect(!model.needsSignIn(account.id))
        #expect(model.retries[account.id]?.failures == 1)
        await model.apply(.init(id: account.id, error: "Socket is not connected", offline: true))
        #expect(model.retries[account.id]?.failures == 2)
        #expect((model.retries[account.id]?.next ?? before) >= before.addingTimeInterval(39))

        // Once it answers, the count starts over.
        await model.apply(.init(id: account.id, mailboxes: [Mailbox(id: "INBOX", name: "Inbox", role: .inbox)]))
        #expect(model.retries[account.id] == nil)
        #expect(!model.isUnreachable(account.id))
    }

    /// When it's due, the unreachable account is fetched again by itself.
    @Test func aDueRetryFetchesTheAccountAgain() async throws {
        let model = MailModel(environment: .preview())
        let account = try #require(model.accounts.first)
        await model.apply(.init(id: account.id, error: "The server took too long to answer.", offline: true))
        #expect(model.isUnreachable(account.id))
        // Not due yet: nothing happens.
        await model.retryUnreachable(now: Date())
        #expect(model.isUnreachable(account.id))
        // Due: the sample account answers, and the trouble is gone.
        await model.retryUnreachable(now: Date().addingTimeInterval(30))
        #expect(!model.isUnreachable(account.id))
        #expect(model.loadErrors[account.id] == nil)
    }
}
