import Foundation
import MailCore
import Observation
import Testing
@testable import MailUI

/// Typing mustn't redraw the window. Views around the editor depend on "is something being
/// written", which only changes when writing starts or stops, never on the text itself.
@MainActor @Suite struct TypingTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    /// Whether anything that was read in `read` changes while `change` runs.
    private func isRedrawn(by change: () -> Void, afterReading read: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        change()
        return flag.fired
    }

    @Test func typingAReplyDoesntRedrawTheConversation() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let thread = try #require(model.inboxThreads(nil).first)
        model.select(thread.id)
        model.startReply()
        #expect(model.isWritingReply)

        // What the conversation reads to decide what to show.
        let conversation = { _ = model.isWritingReply; _ = model.selectedThread }
        #expect(!isRedrawn(by: { model.reply?.draft.text += "H" }, afterReading: conversation))
        #expect(!isRedrawn(by: { model.reply?.to = "sam@example.com" }, afterReading: conversation))
        // Closing the reply is a real change to it.
        #expect(isRedrawn(by: { model.reply = nil }, afterReading: conversation))
        #expect(!model.isWritingReply)
    }

    @Test func typingANewMessageDoesntRedrawTheListAndPane() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.startCompose()
        #expect(model.isWritingNew)

        let pane = { _ = model.isWritingNew; _ = model.isComposePutAway }
        #expect(!isRedrawn(by: { model.compose?.draft.text += "Hello" }, afterReading: pane))
        #expect(!isRedrawn(by: { model.compose?.draft.subject = "Plans" }, afterReading: pane))
        #expect(isRedrawn(by: { model.compose = nil }, afterReading: pane))
        #expect(!model.isWritingNew)
    }

    /// The editor itself does follow the text.
    @Test func theEditorFollowsTheText() async throws {
        let model = MailModel(environment: .preview())
        model.startCompose()
        #expect(isRedrawn(by: { model.compose?.draft.text += "H" }, afterReading: { _ = model.compose }))
    }
}
