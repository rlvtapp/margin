import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct JunkTests {
    @Test func junkLeavesTheInboxAndNotJunkBringsItBack() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = try #require(model.inboxThreads(nil).first)
        let account = try #require(model.account(thread.accountID))
        let junk = try #require(model.mailboxes[account.id]?.first { $0.role == .junk })
        #expect(!model.isJunk(thread))

        await model.apply(.junk, to: [thread], announce: true)
        #expect(!model.inboxThreads(nil).contains { $0.id == thread.id })
        #expect(model.notice?.text == String(localized: "Conversation moved to Junk"))
        await model.flushPendingChange()

        let inJunk = try await model.provider(for: account).threads(in: junk, limit: 50).map { MailModel.tag($0, account: account.id) }
        let reported = try #require(inJunk.first { $0.subject == thread.subject })
        #expect(model.isJunk(reported))

        await model.apply(.notJunk, to: [reported], announce: true)
        #expect(model.notice?.text == String(localized: "Conversation moved to the inbox"))
        await model.flushPendingChange()
        #expect(model.inboxThreads(nil).contains { $0.subject == thread.subject })
    }

    @Test func undoKeepsMailOutOfJunk() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = try #require(model.inboxThreads(nil).first)
        await model.apply(.junk, to: [thread], announce: true)
        model.undo()
        #expect(model.inboxThreads(nil).contains { $0.id == thread.id })
    }
}
