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
        model.addWorkspace(named: "Personal")
        var all = model.workspaces
        all[0].accounts = [work.id]
        // Every other mailbox has a workspace of its own (one in none would show in all of them).
        all[1].accounts = model.accounts.dropFirst().map(\.id)
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
