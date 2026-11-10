import Foundation
import MailCore
import Testing
@testable import MailUI

/// Pins, VIPs, reply reminders, workspaces, writing instructions and settings search.
@MainActor @Suite struct DeskFeatureTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    @Test func pinnedConversationsComeFirstInTheInbox() async throws {
        let model = await model()
        model.go(to: .allInboxes)
        let last = try #require(model.visibleThreads.last)
        #expect(model.visibleThreads.first?.id != last.id)
        model.togglePin(last)
        #expect(model.isPinned(last))
        #expect(model.visibleThreads.first?.id == last.id)
        model.togglePin(last)
        #expect(!model.isPinned(last))
        #expect(model.visibleThreads.first?.id != last.id)
    }

    @Test func vipsListOnlyTheirMail() async throws {
        let model = await model()
        let thread = try #require(model.inboxThreads(nil).first)
        let sender = thread.latest.from
        #expect(!model.isVIP(sender))
        model.toggleVIP(sender)
        #expect(model.isVIP(EmailAddress(address: sender.address.uppercased())))
        model.go(to: .vips(account: nil))
        #expect(!model.visibleThreads.isEmpty)
        #expect(model.visibleThreads.allSatisfy { $0.messages.contains { model.isVIP($0.from) } })
        model.toggleVIP(sender)
        #expect(!model.isVIP(sender))
    }

    @Test func aReplyReminderGoesQuietlyWhenSomeoneAnswered() async throws {
        let model = await model()
        let thread = try #require(model.inboxThreads(nil).first)
        let accountID = try #require(thread.accountID)
        let answered = ReplyReminder(accountID: accountID, recipients: [thread.latest.from.address.lowercased()],
                                     subject: Subject.normalized(thread.subject), sentAt: .distantPast, remindAt: .distantPast)
        #expect(model.gotReply(to: answered))
        var waiting = answered
        waiting.id = UUID()
        waiting.sentAt = .distantFuture
        #expect(!model.gotReply(to: waiting))

        model.notice = nil
        model.replyReminders = [answered]
        model.checkReplyReminders()
        #expect(model.replyReminders.isEmpty)
        #expect(model.notice == nil)

        model.replyReminders = [waiting]
        model.checkReplyReminders()
        #expect(model.replyReminders.isEmpty)
        #expect(model.notice != nil)
    }

    @Test func remindersThatAreNotDueStay() async throws {
        let model = await model()
        let reminder = ReplyReminder(accountID: UUID(), recipients: ["a@example.com"], subject: "x",
                                     sentAt: Date(), remindAt: .distantFuture)
        model.replyReminders = [reminder]
        model.checkReplyReminders()
        #expect(model.replyReminders == [reminder])
    }

    @Test func aWorkspaceShowsOnlyItsMailboxes() async throws {
        let model = await model()
        try #require(model.accounts.count >= 2)
        let work = model.accounts[0]
        let other = model.accounts[1]
        model.addWorkspace(named: "Work")
        var all = model.workspaces
        all[0].accounts = [work.id]
        model.workspaces = all
        let workspace = try #require(model.workspaces.first)

        model.switchWorkspace(to: workspace.id)
        #expect(model.currentWorkspace?.name == "Work")
        #expect(model.workspaceAccounts.map(\.id) == [work.id])
        #expect(model.visibleThreads.allSatisfy { $0.accountID == work.id })
        let otherThread = try #require(model.inboxThreads(other.id).first)
        #expect(model.isInOtherWorkspace(otherThread))
        #expect(model.unreadCount(in: workspace) == model.inboxThreads(work.id).filter(\.isUnread).count)

        // Deleting the workspace in view goes back to every mailbox.
        model.workspaces = []
        #expect(model.currentWorkspaceID == nil)
        #expect(model.workspaceAccounts.count == model.accounts.count)
        #expect(!model.isInOtherWorkspace(otherThread))
    }

    @Test func writingInstructionsReachTheAssistant() async throws {
        let model = await model()
        let account = try #require(model.accounts.first)
        model.learnsWriting = false
        model.writingInstructions = ""
        #expect(model.writingStyle(for: nil, account: account) == nil)
        model.writingInstructions = "No exclamation marks."
        let style = try #require(model.writingStyle(for: nil, account: account))
        #expect(style.contains("No exclamation marks."))
        model.writingInstructions = "   "
        #expect(model.writingStyle(for: nil, account: account) == nil)
    }

    @Test func settingsSearchFindsPagesByWhatIsOnThem() {
        #expect(SettingsPage.reading.matches(""))
        #expect(SettingsPage.reading.matches("tracker"))
        #expect(SettingsPage.notifications.matches("VIP"))
        #expect(SettingsPage.connections.matches("mcp"))
        #expect(!SettingsPage.about.matches("tracker"))
        #expect(SettingsPage.available.contains { $0.matches("workspace") })
    }
}

@Suite struct BlockComposerTests {
    @Test func structuredBodyBecomesHTMLAndKeepsTheSignature() {
        var draft = Draft(from: EmailAddress(address: "alex@example.com"))
        draft.text = "old"
        let document = MailDocument(blocks: [.heading(level: 2, [.init("Notes")]), .bullets([[.init("one")], [.init("two")]])])
        let built = MailModel.applying(document, plain: nil, to: draft, signature: "-- \nAlex Rivera")
        #expect(built.html?.contains("<h3") == true)
        #expect(built.html?.contains("Alex Rivera") == true)
        #expect(built.text == "## Notes\n\n- one\n- two\n\n-- \nAlex Rivera")
    }

    @Test func plainBodyStaysPlain() {
        let draft = Draft(from: EmailAddress(address: "alex@example.com"))
        let built = MailModel.applying(MailDocument(blocks: [.paragraph([.init("Hi Maya,")]), .paragraph([.init("See you at 3.")])]),
                                       plain: "Hi Maya,\n\nSee you at 3.", to: draft, signature: "")
        #expect(built.html == nil)
        #expect(built.text == "Hi Maya,\n\nSee you at 3.")
    }
}

import NativeEditor

@Suite struct EditorBlocksToEmailTests {
    func block(_ type: String, _ text: String, level: Int? = nil, checked: Bool? = nil, marks: [EditorMark] = []) -> EditorBlock {
        EditorBlock(id: UUID().uuidString, depth: 0, kind: EditorBlockKind(type, level: level, checked: checked), text: text, marks: marks)
    }

    func mark(_ start: Int, _ end: Int, _ kind: String, _ value: String? = nil) -> EditorMark {
        let json = #"{"range":{"start":\#(start),"end":\#(end)},"kind":"\#(kind)""# + (value.map { #","value":"\#($0)"}"# } ?? "}")
        return try! JSONDecoder().decode(EditorMark.self, from: Data(json.utf8))
    }

    @Test func editorBlocksBecomeEmailBlocks() {
        let blocks = [
            block("heading", "Plan", level: 1),
            block("paragraph", "Read this first", marks: [mark(0, 4, "bold"), mark(10, 15, "link", "https://example.com")]),
            block("paragraph", ""),
            block("bullet", "one"), block("bullet", "two"),
            block("todo", "Send deck", checked: false), block("todo", "Book room", checked: true),
            block("callout", "Heads up"),
            block("divider", ""),
            block("page_link", ""),
        ]
        let document = MailDocument(blocks: blocks)
        #expect(document.blocks.count == 6)
        #expect(document.blocks[0] == MailDocument.Block.heading(level: 1, [MailDocument.Run("Plan")]))
        #expect(document.blocks[1] == MailDocument.Block.paragraph([MailDocument.Run("Read", bold: true), MailDocument.Run(" this "), MailDocument.Run("first", link: URL(string: "https://example.com"))]))
        #expect(document.blocks[2] == MailDocument.Block.bullets([[MailDocument.Run("one")], [MailDocument.Run("two")]]))
        guard case .tasks(let tasks) = document.blocks[3] else { Issue.record("no tasks"); return }
        #expect(tasks.map(\.done) == [false, true])
        #expect(document.blocks[4] == MailDocument.Block.quote([MailDocument.Run("Heads up")]))
        #expect(document.blocks[5] == MailDocument.Block.divider)
    }
}
