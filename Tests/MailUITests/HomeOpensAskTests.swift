import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct HomeOpensAskTests {
    @Test func homeLeavesTheReaderToAskUntilAConversationIsClicked() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.go(to: .allInboxes)
        #expect(model.selectedThreadID != nil)   // the inbox opens its top conversation

        model.go(to: .home(group: nil))
        if model.isAssistantOn {
            #expect(model.selectedThreadID == nil)   // the pane is Ask
            await model.reload()
            #expect(model.selectedThreadID == nil)   // and stays so after new mail
        } else {
            #expect(model.selectedThreadID != nil)   // nothing to ask: the top conversation
        }
    }

    @Test func withoutAnAssistantAskIsNowhere() async {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.intelligence = nil   // no Apple Intelligence on this device, and no other service
        #expect(!model.isAssistantOn)
        model.go(to: .home(group: nil))
        #expect(model.selectedThreadID != nil)   // Home opens mail instead of an Ask pane
        #expect(!model.offersAsk(for: "when is my flight?"))
        #expect(!MailCommand.all(for: model).contains { $0.id == "ask" || $0.id == "agent.ask" })
    }
}
