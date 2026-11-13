import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AskPreferencesTests {
    @Test func preferencesShapeTheAnswer() {
        var preferences = AskPreferences()
        #expect(preferences.style.isEmpty)
        preferences.length = .brief
        preferences.instructions = "Answer in Dutch"
        #expect(preferences.style.contains("under 40 words") && preferences.style.contains("Answer in Dutch"))
        // Saved before these existed: everything takes its default.
        let old = try? JSONDecoder().decode(AskPreferences.self, from: Data("{}".utf8))
        #expect(old == AskPreferences())
    }

    @Test func onlyTheMailboxInViewWhenAskedFor() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let all = model.inboxThreads(nil)
        let account = try #require(all.first?.accountID)
        model.go(to: .inbox(account: account, split: nil))
        #expect(model.askScope(all).count == all.count)
        var preferences = model.askPreferences
        preferences.onlyMailboxInView = true
        model.askPreferences = preferences
        #expect(model.askScope(all).allSatisfy { $0.accountID == account })
        #expect(model.askScope(all).count < all.count)
    }

    @Test func newSlashCommands() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        #expect(AskCommand.matching("/rep").contains(.replies) && AskCommand.matching("/uns") == [.unsubscribe])
        model.send(askInput: "/unsubscribe")
        #expect(model.place == .subscriptions)
        model.send(askInput: "/replies")
        #expect(model.currentAskChat?.turns.last?.question == "/replies")
    }
}
