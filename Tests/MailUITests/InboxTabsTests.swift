import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct InboxTabsTests {
    @Test func importantIsPeopleAndOtherIsEverythingElse() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let inbox = model.inboxThreads(nil)
        let people = inbox.filter { $0.split == .people }
        let other = inbox.filter { $0.split != .people }
        try #require(!people.isEmpty && other.contains { $0.split == .newsletters } && other.contains { $0.split == .updates })

        model.go(to: .inbox(account: nil, split: .people))
        #expect(Set(model.visibleThreads.map(\.id)) == Set(people.filter { !model.isSnoozed($0) }.map(\.id)))
        model.go(to: .inbox(account: nil, split: .updates))
        #expect(Set(model.visibleThreads.map(\.id)) == Set(other.filter { !model.isSnoozed($0) }.map(\.id)))

        #expect(model.unreadCount(account: nil, split: .updates) == other.filter(\.isUnread).count)
        #expect(model.unreadCount(account: nil, split: .newsletters) == other.filter(\.isUnread).count)
        #expect(model.unreadCount(account: nil, split: .people) == people.filter(\.isUnread).count)
        #expect(InboxSplit.tabs.map(\.tabTitle) == ["Important", "Other"])
    }
}
