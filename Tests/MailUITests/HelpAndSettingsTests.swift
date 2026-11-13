import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct HelpAndSettingsTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    @Test func feedbackIsAMessageToTheTeamReadyToSend() async throws {
        let model = await model()
        model.isShowingHelp = true
        model.startFeedback("Dark mode is lovely")
        let draft = try #require(model.compose)
        #expect(draft.to == "hello@relevate.app")
        #expect(draft.draft.subject == "Margin feedback")
        #expect(draft.draft.text.hasPrefix("Dark mode is lovely\n\n— Margin "))
        #expect(!model.isShowingHelp)

        // From Ask: "/feedback …" with what follows the command.
        model.compose = nil
        model.send(askInput: "/feedback  Please add a dark icon")
        #expect(model.compose?.draft.text.hasPrefix("Please add a dark icon") == true)
        model.startFeedback(problem: true)
        #expect(model.compose?.draft.subject == "Margin: a problem")
    }

    @Test func settingsGoBackAndForwardLikeABrowser() {
        var history = SettingsHistory()
        history.visited(from: .mailboxes, to: .notifications)
        history.visited(from: .notifications, to: .rules)
        #expect(history.canGoBack && !history.canGoForward)
        #expect(history.back(from: .rules) == .notifications)
        history.isMoving = true
        history.visited(from: .rules, to: .notifications)   // the move itself isn't a visit
        #expect(history.back(from: .notifications) == .mailboxes)
        #expect(history.forward(from: .mailboxes) == .notifications)
        #expect(history.forward(from: .notifications) == .rules)
        #expect(!history.canGoForward)
        // A new page after going back drops what was ahead.
        _ = history.back(from: .rules)
        history.visited(from: .notifications, to: .about)
        #expect(!history.canGoForward)
    }

    @Test func remindersHaveTheirOwnSound() async {
        let model = await model()
        #expect(model.reminderSound.name == "default")
        model.reminderSound = .none
        #expect(model.reminderSound == .none)
        #if canImport(UserNotifications)
        #expect(MailModel.notificationSound(.none) == nil)
        #expect(MailModel.notificationSound(.standard) != nil)
        #endif
    }

    @Test func aReplyToOneMessageOpensUnderIt() async throws {
        let model = await model()
        let thread = try #require(model.inboxThreads(nil).first { $0.messages.count > 1 })
        model.select(thread.id)
        model.startReply()
        #expect(model.reply?.answersOneMessage == false)
        model.startReply(to: thread.messages[0])
        #expect(model.reply?.answersOneMessage == true)
        #expect(model.reply?.draft.inReplyTo == thread.messages[0].messageID)
    }
}
