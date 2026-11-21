import Foundation
import MailCore
import Testing
@testable import MailUI

/// A server that takes its time with folders: what's saved on this Mac has to carry the list.
private actor SlowFolders: MailProvider {
    var asked = 0
    func mailboxes() async throws -> [Mailbox] { BenchmarkMail.folders }
    func threads(in mailbox: Mailbox, limit: Int) async throws -> [MailThread] {
        asked += 1
        try await Task.sleep(for: .seconds(30))
        return []
    }
    func body(of message: MailMessage) async throws -> MessageBody { MessageBody(text: "") }
    func perform(_ action: MailAction, on threads: [MailThread]) async throws {}
    func send(_ draft: Draft) async throws {}
    func disconnect() async {}
}

/// Scrolling down a folder shows its next page from saved mail at once, instead of waiting for
/// the server to send the whole folder again.
@MainActor @Suite(.serialized) struct FolderPagingTests {
    @Test func theNextPageOfAFolderComesFromSavedMail() async throws {
        var environment = MailEnvironment.preview()
        let url = FileManager.default.temporaryDirectory.appending(path: "margin-folder-\(UUID().uuidString)/mail.sqlite")
        environment.cache = MailCache(url: url)
        let model = MailModel(environment: environment)
        let mail = BenchmarkMail(accounts: 1, now: Date(timeIntervalSince1970: 1_800_000_000))
        let account = mail.accounts[0]
        model.accounts = [account]
        let provider = SlowFolders()
        model.providers[account.id] = provider
        model.mailboxes[account.id] = BenchmarkMail.folders
        let sent = BenchmarkMail.folders[1]
        let saved = (0..<600).map { index in
            var thread = mail.thread(index, mailbox: 0)
            thread.messages = thread.messages.map { var message = $0; message.mailboxID = sent.id; return message }
            return thread
        }
        await environment.cache.saveThreads(saved, account: account.id, mailbox: sent.id, limit: 600)

        model.go(to: .mailbox(account: account.id, sent))
        for _ in 0..<200 where model.folder.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let first = model.folder.count
        #expect(first == MailModel.listPage)

        // The end of the list: the next page shows long before the server would answer.
        model.listWindow = model.listCount
        model.listReachedEnd()
        for _ in 0..<200 where model.folder.count == first { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.folder.count > first)
        #expect(model.listHasMoreRows || model.listCount > first)
        // Still newest first: older mail only goes after what was on screen.
        let dates = model.folder.map(\.date)
        #expect(dates == dates.sorted(by: >))
    }
}
