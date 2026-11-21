import Foundation
import MailCore
import Testing
@testable import MailUI

/// A server that takes the whole message and then loses the connection before saying so.
private actor UnconfirmedProvider: MailProvider {
    var sendAttempts = 0
    var drafts: [Draft] = []

    func send(_ draft: Draft) async throws {
        sendAttempts += 1
        throw MailError.deliveryUnconfirmed
    }

    func saveDraft(_ draft: Draft) async throws { drafts.append(draft) }
    func mailboxes() async throws -> [Mailbox] { [] }
    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] { [] }
    func body(of message: MailMessage) async throws -> MessageBody { MessageBody(text: "") }
    func perform(_ action: MailAction, on threads: [MailThread]) async throws {}
    func attachmentData(_ attachment: AttachmentInfo, of message: MailMessage) async throws -> Data { Data() }
    func disconnect() async {}
}

/// A message the server probably took is never sent a second time, and isn't lost either.
@MainActor @Suite struct UnconfirmedSendTests {
    private func setup() throws -> (MailModel, UnconfirmedProvider, MailAccount) {
        let environment = MailEnvironment.preview()
        let account = MailAccount(label: "Work", address: EmailAddress(address: "me@example.com"),
                                  connection: .sample, auth: .password(username: "me"))
        try environment.accounts.save([account])
        let model = MailModel(environment: environment)
        let provider = UnconfirmedProvider()
        model.providers[account.id] = provider
        return (model, provider, account)
    }

    private func message(from account: MailAccount) -> ComposeState {
        var state = ComposeState(account: account)
        state.to = "sam@kettle.example"
        state.draft.subject = "Quarter plan"
        state.draft.text = "Here it is."
        return state
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition())
    }

    @Test func afterUndoSendItIsKeptNotQueued() async throws {
        let (model, provider, account) = try setup()
        model.undoSendDelay = 0
        model.queueSend(message(from: account), isReply: false)
        try await waitFor { await provider.drafts.count == 1 }

        #expect(await provider.sendAttempts == 1)
        #expect(model.outbox.isEmpty)
        #expect(model.compose == nil)
        #expect(model.notice?.isError == false)
        #expect(await provider.drafts.first?.subject == "Quarter plan")

        // The clock keeps running; nothing goes out again.
        await model.tick()
        await model.tick()
        #expect(await provider.sendAttempts == 1)
    }

    @Test func aWaitingOutboxMessageLeavesTheOutbox() async throws {
        let (model, provider, account) = try setup()
        let draft = try message(from: account).validated()
        model.outbox = [ScheduledMessage(accountID: account.id, draft: draft, sendAt: Date().addingTimeInterval(-1),
                                         waitsForConnection: true)]
        await model.tick()
        try await waitFor { await provider.drafts.count == 1 }

        #expect(model.outbox.isEmpty)
        await model.tick()
        #expect(await provider.sendAttempts == 1)
    }

    @Test func sendingDirectlyReportsItWithoutAnError() async throws {
        let (model, provider, account) = try setup()
        let sent = await model.send(message(from: account))
        try await waitFor { await provider.drafts.count == 1 }

        #expect(!sent)
        #expect(model.notice?.isError == false)
        #expect(await provider.sendAttempts == 1)
    }

    @Test func itIsNotAConnectionProblem() {
        #expect(!MailError.isConnectionProblem(MailError.deliveryUnconfirmed))
    }
}
