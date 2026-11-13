import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct MutationRefreshTests {
    @Test func aRefreshCannotResurrectABulkDeleteDuringUndo() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let original = model.inboxThreads(account.id)
        #expect(original.count > 1)
        await model.apply(.trash, to: original, announce: false)
        defer { model.undo() }
        let revision = model.mutationRevision
        let result = MailModel.LoadedAccount(id: account.id, mutationRevision: revision,
                                            threads: original)
        #expect(!model.take(result).changed)
        #expect(model.inboxThreads(account.id).isEmpty)
        model.undo()
        #expect(Set(model.inboxThreads(account.id).map(\.id)) == Set(original.map(\.id)))
        // An answer begun before Undo cannot overwrite the restored list either.
        #expect(!model.take(result).changed)
        #expect(model.inboxThreads(account.id).count == original.count)
    }

    @Test func aRefreshBegunBeforeACommitCannotReplaceItsResult() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let original = model.inboxThreads(account.id)
        let stale = MailModel.LoadedAccount(id: account.id, mutationRevision: model.mutationRevision,
                                           threads: original)
        await model.apply(.trash, to: original, announce: false)
        await model.flushPendingChange()
        #expect(!model.take(stale).changed)
        #expect(model.inboxThreads(account.id).isEmpty)
        // An answer arriving while a write is running is also deferred.
        model.committingChanges[account.id] = 1
        let during = MailModel.LoadedAccount(id: account.id, mutationRevision: model.mutationRevision,
                                            threads: original)
        #expect(!model.take(during).changed)
        model.committingChanges[account.id] = nil
        #expect(model.take(during).changed)
    }
}
