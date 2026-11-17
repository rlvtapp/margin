import Foundation
import MailCore
import SwiftUI
import Testing
@testable import MailUI
#if canImport(AppKit)
import AppKit
#endif

/// The reply written bigger, in the reading pane, and where the cursor starts.
@MainActor @Suite struct ReplySizeTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.undoSendDelay = 0
        return model
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    func writingReply(_ model: MailModel) throws -> ComposeState {
        let thread = try #require(model.visibleThreads.first)
        model.select(thread.id)
        model.startReply()
        model.reply?.draft.text = "Thursday works." + (model.reply?.draft.text ?? "")
        return try #require(model.reply)
    }

    @Test func theButtonMakesTheReplyBiggerAndBackAgain() async throws {
        let model = await model()
        let state = try writingReply(model)
        model.toggleReplyExpanded()
        #expect(model.isReplyExpanded)
        // Same reply, same place: nothing about the message changes.
        #expect(model.reply == state)
        model.toggleReplyExpanded()
        #expect(!model.isReplyExpanded)
        #expect(model.reply == state)
    }

    @Test func escShrinksABiggerReplyBeforeClosingIt() async throws {
        let model = await model()
        let state = try writingReply(model)
        model.toggleReplyExpanded()
        model.escapeReply(state)
        #expect(!model.isReplyExpanded)
        #expect(model.reply == state)
        model.escapeReply(state)
        #expect(model.reply == nil)
    }

    @Test func aNewReplyStartsAtItsUsualSize() async throws {
        let model = await model()
        _ = try writingReply(model)
        model.toggleReplyExpanded()
        model.reply = nil
        #expect(!model.isReplyExpanded)
        model.startReply()
        #expect(!model.isReplyExpanded)
        // Nothing to make bigger without a reply.
        model.reply = nil
        model.toggleReplyExpanded()
        #expect(!model.isReplyExpanded)
    }

    @Test func sendingABiggerReplySendsItOnceAndResetsTheSize() async throws {
        let model = await model()
        let state = try writingReply(model)
        let inReplyTo = try #require(state.draft.inReplyTo)
        model.toggleReplyExpanded()
        model.queueSend(state, isReply: true)
        #expect(model.reply == nil)
        #expect(!model.isReplyExpanded)
        try await waitFor { model.notice?.isSent == true }
        model.go(to: .combined(.sent))
        try await waitFor { !model.visibleThreads.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        let sent = model.visibleThreads.flatMap(\.messages).filter { $0.inReplyTo == inReplyTo && $0.mailboxID == "Sent" }
        #expect(sent.count == 1)
    }

    #if canImport(AppKit)
    @Test func writingStartsOnTheFirstLineAboveTheSignature() throws {
        let controller = RichTextController()
        let editor = RichTextEditor(text: .constant("\n\n--\nKaan\nRelevate"), html: .constant(nil), controller: controller)
        let host = NSHostingView(rootView: editor.frame(width: 400, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        let view = try #require(controller.textView)
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
    }
    #endif
}
