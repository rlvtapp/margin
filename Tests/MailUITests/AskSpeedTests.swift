import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AskSpeedTests {
    @Test func questionsTheFactsAnswerSkipTheMailSearch() {
        #expect(MailModel.askTopic("What's on my calendar this week?") == .schedule)
        #expect(MailModel.askTopic("Wat staat er in mijn agenda?") == .schedule)
        #expect(MailModel.askTopic("Any meetings tomorrow?") == .schedule)
        #expect(MailModel.askTopic("Any bills I still need to pay?") == .bills)
        #expect(MailModel.askTopic("What needs a reply from me?") == .replies)
        #expect(MailModel.askTopic("When does my flight to Lisbon leave?") == .general)
        // Naming someone or something else still searches mail.
        #expect(MailModel.askTopic("What did Noor say about the meeting?") == .general)
        #expect(MailModel.askTopic("When is my meeting with Sam?") == .general)
    }

    @Test func waitingStopsAtItsLimitAndTheWorkGoesOn() async {
        let slow = Task { _ = try? await Task.sleep(for: .seconds(10)) }
        let started = ContinuousClock.now
        await MailModel.wait(for: slow, upTo: .milliseconds(100))
        // Well before the slow work is done, even with every other test busy at the same time.
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!slow.isCancelled)   // the refresh carries on in the background
        slow.cancel()
    }

    @Test func aCalendarQuestionReadsOnlyTheMeetingsConversations() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.addSampleMeeting()
        let threads = model.scheduleConversations()
        #expect(threads.count <= 4)
        #expect(threads.allSatisfy { thread in model.calendarEntries.contains { $0.threadID == thread.id } })
    }
}
