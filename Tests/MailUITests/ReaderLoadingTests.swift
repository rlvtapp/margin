import Foundation
import MailCore
import Testing
@testable import MailUI

private actor ReaderProvider: MailProvider {
    var batches: [[String]] = []
    var opened: [String] = []
    let onBatch: @Sendable () async -> Void
    init(onBatch: @escaping @Sendable () async -> Void = {}) { self.onBatch = onBatch }
    func mailboxes() async throws -> [Mailbox] { [] }
    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] { [] }
    func body(of message: MailMessage) async throws -> MessageBody { MessageBody(text: message.id) }
    func openedBody(of message: MailMessage) async throws -> (body: MessageBody, isComplete: Bool) {
        opened.append(message.id)
        return (MessageBody(text: message.id), true)
    }
    func bodies(of messages: [MailMessage]) async throws -> [String: MessageBody] {
        batches.append(messages.map(\.id))
        await onBatch()
        return Dictionary(uniqueKeysWithValues: messages.map { ($0.id, MessageBody(text: $0.id)) })
    }
    func perform(_ action: MailAction, on threads: [MailThread]) async throws {}
    func send(_ draft: Draft) async throws {}
    func saveDraft(_ draft: Draft) async throws {}
    func attachmentData(_ attachment: AttachmentInfo, of message: MailMessage) async throws -> Data { Data() }
    func disconnect() async {}
}

@MainActor @Suite struct ReaderLoadingTests {
    private func setup() throws -> (MailModel, MailThread) {
        let environment = MailEnvironment.preview()
        let account = MailAccount(label: "Reader", address: EmailAddress(address: "me@example.com"),
                                  connection: .sample, auth: .password(username: "me"))
        try environment.accounts.save([account])
        let model = MailModel(environment: environment)
        let messages = (0..<40).map { index in
            MailMessage(id: "INBOX/\(index)", mailboxID: "INBOX", from: account.address,
                        subject: "Long conversation", date: Date(timeIntervalSince1970: Double(index)), flags: [.seen])
        }
        let thread = MailModel.tag(MailThread(id: "conversation", messages: messages), account: account.id)
        model.shelves[account.id] = InboxShelf([thread])
        model.selectedThreadID = thread.id
        return (model, thread)
    }

    @Test func theNewestMessageShowsBeforeHistoryAndHistoryArrivesInBatches() async throws {
        let (model, thread) = try setup()
        let account = try #require(thread.accountID)
        let provider = ReaderProvider {
            await MainActor.run {
                #expect(model.body(of: thread.latest, in: thread)?.text == thread.latest.id)
            }
        }
        model.providers[account] = provider
        await model.loadBodies()
        #expect(await provider.opened == [thread.latest.id])
        let batches = await provider.batches
        #expect(batches.count == 5)
        #expect(batches.allSatisfy { $0.count <= 8 })
        #expect(batches.flatMap { $0 }.count == 39)
        #expect(thread.messages.allSatisfy { model.body(of: $0, in: thread) != nil })
    }

    @Test func leavingAConversationStopsItsRemainingHistoryDownloads() async throws {
        let (model, thread) = try setup()
        let account = try #require(thread.accountID)
        let provider = ReaderProvider {
            await MainActor.run { model.selectedThreadID = nil }
        }
        model.providers[account] = provider
        await model.loadBodies()
        #expect(await provider.batches.count == 1)
        #expect(model.body(of: thread.latest, in: thread)?.text == thread.latest.id)
    }
}
