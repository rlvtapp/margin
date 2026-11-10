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

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
