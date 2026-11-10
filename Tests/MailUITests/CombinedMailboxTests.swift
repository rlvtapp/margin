import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct CombinedMailboxTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    @Test func allInboxesMergesEveryMailbox() async {
        let model = await model()
        let work = model.accounts[0].id, personal = model.accounts[1].id
        let all = model.visibleThreads
        #expect(Set(all.compactMap(\.accountID)) == [work, personal])
        #expect(all.count == model.inboxThreads(work).count + model.inboxThreads(personal).count)
        #expect(all.map(\.date) == all.map(\.date).sorted(by: >))
    }

    @Test func combinedSentHoldsEachMailboxsSent() async throws {
        let model = await model()
        model.go(to: .combined(.sent))
        try await waitFor { !model.folder.isEmpty }
        let subjects = Set(model.visibleThreads.map(\.subject))
        #expect(subjects == ["Hiring plan draft", "Contract renewal", "Flat keys"])
        #expect(model.title == "Sent")
        #expect(model.place.isCombined)
        #expect(model.combinedRoles == [.drafts, .sent, .archive, .junk, .trash])
    }

    @Test func doneLeavesTheListAndUndoBringsItBack() async throws {
        let model = await model()
        let first = try #require(model.visibleThreads.first)
        model.select(first.id)
        model.perform(.done)
        try await waitFor { !model.visibleThreads.contains { $0.id == first.id } }
        #expect(model.notice?.canUndo == true)
        model.undo()
        #expect(model.visibleThreads.contains { $0.id == first.id })
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
