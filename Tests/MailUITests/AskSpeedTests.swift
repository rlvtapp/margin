import Foundation
@testable import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AskSpeedTests {
    /// What to look up is the model's call; its answer is read back as given.
    @Test func theModelPlansWhatToLookUp() {
        #expect(MailIntelligence.parsePlan(#"{"search": "Sam invoice", "calendar": false}"#) == AskPlan(search: "Sam invoice", calendar: false))
        #expect(MailIntelligence.parsePlan(#"Plan: {"search": "", "calendar": true}"#) == AskPlan(search: "", calendar: true))
        #expect(MailIntelligence.parsePlan("no idea") == AskPlan(search: "", calendar: false))
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
