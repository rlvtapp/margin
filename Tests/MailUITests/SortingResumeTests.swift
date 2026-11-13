import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct SortingResumeTests {
    @Test func remembersWhatItLookedAtSoItResumes() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let todo = model.inboxThreads(nil).filter(model.needsSorting)
        #expect(!todo.isEmpty)

        // The rules alone, so the test doesn't wait on a language model.
        model.intelligence = nil
        model.sortNow()
        try await waitFor { !model.isSorting }
        // Everything was looked at, sorted or not; a second run has nothing to do.
        #expect(model.inboxThreads(nil).filter(model.needsSorting).isEmpty)

        // A new message in a conversation makes it worth another look.
        let thread = todo[0]
        if model.group(of: thread) == nil {
            model.sortingChecked[LabelStore.key(for: thread)] = "older"
            #expect(model.needsSorting(thread))
        }
    }

    @Test func takingOneOutOfItsGroupLetsSortNowLookAgain() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = try #require(model.inboxThreads(nil).first)
        let travel = try #require(model.emailGroups.first { $0.name == "Travel" })

        // The label's ✕: Sort Now looks at it again.
        model.move(thread, toGroup: travel)
        #expect(!model.needsSorting(thread))
        model.removeLabel(travel.name, from: thread)
        #expect(model.needsSorting(thread))

        // "Not in a group": it stays out.
        model.move(thread, toGroup: travel)
        model.move(thread, toGroup: nil)
        #expect(model.group(of: thread) == nil)
        #expect(!model.needsSorting(thread))
        #expect(!model.canSortAgain(thread))
    }

    @Test func sortNowWithNothingNewLooksAgain() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.intelligence = nil
        model.sortNow()
        try await waitFor { !model.isSorting }
        let unsorted = model.inboxThreads(nil).filter { model.group(of: $0) == nil }
        try #require(unsorted.count >= 2)
        // One taken out by hand stays out; the rest are looked at again.
        model.sortingChecked[LabelStore.key(for: unsorted[0])] = MailModel.keptOut + MailModel.sortingMark(unsorted[0])
        model.sortNow()
        #expect(model.sortingProgress?.total == unsorted.count - 1)
        try await waitFor { !model.isSorting }
        // Once: a third click with nothing new doesn't go round again.
        model.sortNow()
        #expect(!model.isSorting)
        #expect(model.notice?.text == "Nothing new to sort")
    }

    @Test func sortsWithTheAssistantInBatches() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let todo = model.inboxThreads(nil).filter(model.needsSorting)
        let travel = try #require(model.emailGroups.first { $0.name == "Travel" })
        let counter = BatchModel()
        let intelligence = MailIntelligence(model: counter)
        let picked = await MailModel.pickGroups(for: Array(todo.prefix(5)), among: model.emailGroups, using: intelligence)
        // The model fails any batch with more than two conversations, so the batch is split
        // until it answers; every conversation still gets the assistant's pick.
        #expect(picked.count == min(todo.count, 5))
        #expect(picked.values.allSatisfy { $0 == travel })
        #expect(counter.calls > 1)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

/// Puts everything in Travel, but fails a batch of more than two conversations.
private final class BatchModel: MailLanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    var attribution: String { "by test" }
    var transcriptBudget: Int { 6_000 }
    func summary(_ request: ModelRequest) async throws -> ThreadSummary { ThreadSummary(headline: "x", points: [], action: nil) }
    func labels(_ request: ModelRequest) async throws -> [String] { [] }
    func answer(_ request: ModelRequest) async throws -> MailAnswer { MailAnswer(text: "", sources: []) }
    func reply(_ request: ModelRequest) async throws -> String {
        lock.withLock { count += 1 }
        let numbers = (1...20).filter { request.prompt.contains("\n\($0). From:") || request.prompt.contains(":\n\n\($0). From:") }
        if numbers.count > 2 { throw URLError(.cannotParseResponse) }
        return numbers.map { "\($0): Travel" }.joined(separator: "\n")
    }
}
