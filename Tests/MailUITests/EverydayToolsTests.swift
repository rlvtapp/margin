import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct EverydayToolsTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func snoozeHidesAndUndoBringsBack() async throws {
        let model = await model()
        let first = try #require(model.visibleThreads.first)
        model.select(first.id)
        model.snooze(until: Date().addingTimeInterval(3600))
        #expect(!model.visibleThreads.contains { $0.id == first.id })
        model.go(to: .snoozed(account: nil))
        #expect(model.visibleThreads.map(\.id) == [first.id])
        model.go(to: .allInboxes)
        model.select(first.id)
        model.undo()
        #expect(model.visibleThreads.contains { $0.id == first.id })
    }

    @Test func wokenSnoozesReturn() async throws {
        let model = await model()
        let first = try #require(model.visibleThreads.first)
        model.select(first.id)
        model.snooze(until: Date().addingTimeInterval(0.05))
        try await Task.sleep(for: .milliseconds(100))
        await model.tick()
        #expect(model.visibleThreads.contains { $0.id == first.id })
        #expect(model.snoozes.isEmpty)
    }

    @Test func undoSendReopensTheMessage() async throws {
        let model = await model()
        model.undoSendDelay = 5
        model.startCompose()
        var state = try #require(model.compose)
        state.to = "sam@kettle.example"
        state.draft.subject = "Hello"
        model.queueSend(state, isReply: false)
        #expect(model.compose == nil)
        #expect(model.notice?.undo == .send)
        model.undo()
        #expect(model.compose?.draft.subject == "Hello")
    }

    @Test func sendLaterGoesOutWhenDue() async throws {
        let model = await model()
        model.startCompose()
        var state = try #require(model.compose)
        state.to = "sam@kettle.example"
        state.draft.subject = "Later"
        model.schedule(state, at: Date().addingTimeInterval(-1), isReply: false)
        #expect(model.outbox.count == 1)
        await model.tick()
        #expect(model.outbox.isEmpty)
        model.go(to: .combined(.sent))
        try await waitFor { model.visibleThreads.contains { $0.subject == "Later" } }
    }

    @Test func findsMailWaitingForReply() async throws {
        let model = await model()
        model.go(to: .waiting(account: nil))
        try await waitFor { !model.folder.isEmpty }
        #expect(Set(model.visibleThreads.map(\.subject)) == ["Contract renewal", "Flat keys"])
        #expect(model.waitingCount == 2)
        // Back again later: there at once, from the last visit, while it's checked again.
        model.go(to: .allInboxes)
        model.go(to: .waiting(account: nil))
        #expect(Set(model.visibleThreads.map(\.subject)) == ["Contract renewal", "Flat keys"])
    }

    /// They answered with a meeting invitation instead of a reply (Outlook then moves it to
    /// Deleted Items): you're no longer waiting on them.
    @Test func anInvitationCountsAsAnAnswer() async throws {
        let model = await model()
        let account = try #require(model.accounts.first)
        let sam = EmailAddress(name: "Sam Okafor", address: "sam@kettle.example")
        let invitation = MailMessage(id: "invite-1", mailboxID: "Deleted Items", messageID: "invite-1@kettle.example", from: sam,
                                     to: [account.address], subject: "Invitation: Renewal call @ Tue 15:00", date: Date())
        await model.environment.cache.saveThreads([MailThread(id: "invite-1", messages: [invitation])], account: account.id,
                                                  mailbox: "Deleted Items")
        let waiting = await model.waitingThreads(nil)
        #expect(Set(waiting.map(\.subject)) == ["Flat keys"])
    }

    @Test func bulkActionsAndFilters() async throws {
        let model = await model()
        let threads = Array(model.visibleThreads.prefix(2))
        model.select(threads[0].id)
        model.toggleSelection(threads[1].id)
        #expect(model.actionTargets.count == 2)
        model.perform(.done)
        try await waitFor { !model.visibleThreads.contains { $0.id == threads[1].id } }
        #expect(model.selection.isEmpty)

        model.quickFilters = [.attachments]
        let filtered = model.visibleThreads
        let allHaveFiles = filtered.allSatisfy { $0.hasAttachments }
        #expect(allHaveFiles)
        #expect(!filtered.isEmpty)
    }

    @Test func signaturesAndForgottenAttachments() async throws {
        let model = await model()
        let account = model.accounts[0]
        model.setSignature("Alex\nNorthwind", for: account.id)
        model.go(to: .inbox(account: account.id, split: nil))
        model.startCompose()
        var state = try #require(model.compose)
        // The signature, then "Sent from Margin" last.
        #expect(state.draft.text == "\n\nAlex\nNorthwind\n\nSent from Margin")
        state.send(from: model.accounts[1], previous: model.account(account.id))
        #expect(state.draft.text == "\n\nSent from Margin")

        state.draft.text = "Attached is the plan."
        #expect(state.forgotAttachment)
        state.draft.attachments = [OutgoingAttachment(filename: "plan.pdf", mimeType: "application/pdf", data: Data([1]))]
        #expect(!state.forgotAttachment)
    }

    @Test func unsubscribeAndCodes() async throws {
        let model = await model()
        let weekly = try #require(model.inboxThreads(nil).first { $0.subject.hasPrefix("Issue 212") })
        #expect(model.unsubscribeMethod(for: weekly) == .oneClick(URL(string: "https://weekly.example/leave/8812")!))
        #expect(model.threadsFromSameSender(as: weekly).count == 2)
        let code = try #require(model.inboxThreads(nil).first { $0.subject == "Your Kettle sign-in code" })
        #expect(model.signInCode(in: code) == "482913")
    }
}
