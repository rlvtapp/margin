import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct SnoozedCopiesTests {
    @Test func snoozedShowsAtOnceEvenWhenTheInboxNoLongerHoldsIt() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let account = try #require(model.accounts.first)
        let thread = try #require(model.inboxThreads(account.id).last)
        model.snooze(thread, until: Date().addingTimeInterval(86_400))

        // The inbox lets go of older mail (as switching pages does with a long inbox).
        model.shelves[account.id]?.trim(to: 0)
        #expect(!model.inboxThreads(account.id).contains { $0.id == thread.id })

        // Snoozed still has it, straight away: nothing to load first.
        model.go(to: .snoozed(account: nil))
        #expect(model.visibleThreads.map(\.id) == [thread.id])
        #expect(model.listCount == 1)

        // Unsnoozed, it's gone from Snoozed and its copy with it.
        model.unsnooze(thread)
        #expect(model.visibleThreads.isEmpty && model.snoozedCopies.isEmpty)
    }
}
