import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AskChatTests {
    @Test func commandsAnswerInTheSameChatAndAreKept() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        await model.refreshNewsletterHistory()
        model.send(askInput: "/help")
        model.send(askInput: "/cleanup")
        let chat = try #require(model.currentAskChat)
        #expect(chat.turns.map(\.question) == ["/help", "/cleanup"])
        #expect(chat.turns[0].answer.contains("/waiting"))
        #expect(chat.turns[1].answer.contains("Open Standards Digest"))
        #expect(!chat.turns[1].sources.isEmpty)
        model.newAskChat()
        #expect(model.currentAskChat == nil)
        #expect(model.askChats.count == 1)
        #expect(AskCommand.matching("/w") == [.waiting])
    }
}
