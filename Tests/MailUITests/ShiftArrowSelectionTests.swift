import Foundation
import Testing
@testable import MailUI

/// ⇧↓ and ⇧↑ select further rows from the open conversation.
@MainActor @Suite struct ShiftArrowSelectionTests {
    @Test func growsAndShrinksFromTheOpenConversation() async throws {
        let model = MailModel(environment: .preview())
        await model.start()
        let threads = model.listSections(model.visibleThreads)?.flatMap(\.threads) ?? model.visibleThreads
        try #require(threads.count >= 4)
        model.select(threads[1].id)
        model.extendSelection(by: 1)
        model.extendSelection(by: 1)
        #expect(model.selection == Set(threads[1...3].map(\.id)))
        #expect(model.selectedThreadID == threads[1].id)
        #expect(model.selectionEnd == threads[3].id)
        // Back up: it shrinks, down to nothing selected but the open one, then grows upwards.
        model.extendSelection(by: -1)
        #expect(model.selection == Set(threads[1...2].map(\.id)))
        model.extendSelection(by: -1)
        #expect(model.selection.isEmpty)
        model.extendSelection(by: -1)
        #expect(model.selection == Set(threads[0...1].map(\.id)))
    }
}
