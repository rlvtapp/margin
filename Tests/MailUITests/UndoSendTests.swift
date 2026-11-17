import Foundation
import MailCore
import Testing
@testable import MailUI
#if canImport(AppKit)
import AppKit
#endif

/// Undo Send: the message isn't sent, and comes back exactly as it was written.
@MainActor @Suite struct UndoSendTests {
    func model(delay: Int = 1) async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.undoSendDelay = delay
        return model
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// Everything a message can carry, so a restore that drops anything shows up.
    func fullMessage(in model: MailModel) throws -> ComposeState {
        model.startCompose()
        var state = try #require(model.compose)
        state.to = "sam@kettle.example"
        state.cc = "noor@post.example"
        state.showsCc = true
        state.bcc = "ana@ledger.example"
        state.showsBcc = true
        state.draft.subject = "Quarter plan"
        state.draft.text = "Here it is, bold and all."
        state.draft.html = "<div><b>Here it is</b>, bold and all.</div>"
        state.draft.inReplyTo = "<a1@post.example>"
        state.draft.references = ["<a0@post.example>", "<a1@post.example>"]
        state.draft.attachments = [
            OutgoingAttachment(filename: "plan.pdf", mimeType: "application/pdf", data: Data("%PDF".utf8)),
            OutgoingAttachment(filename: "chart.png", mimeType: "image/png", data: Data([1, 2, 3]),
                               contentID: "picture-1\(EmailHTMLWriter.inlineSuffix)"),
        ]
        state.draft.from = EmailAddress(name: "Sales", address: "sales@kettle.example")
        state.remindAfterDays = 3
        let original = MailMessage(id: "f1", mailboxID: "INBOX", from: EmailAddress(address: "noor@post.example"),
                                   to: [EmailAddress(address: "me@home.example")], subject: "Numbers", date: Date())
        state.forwarded = ForwardedOriginal(message: original, body: MessageBody(text: "Numbers", html: "<p>Numbers</p>"))
        return state
    }

    @Test func undoBringsBackTheWholeMessageAndSendsNothing() async throws {
        let model = await model()
        let state = try fullMessage(in: model)
        model.queueSend(state, isReply: false)
        #expect(model.compose == nil)
        #expect(model.notice?.undo == .send)

        model.undo()
        #expect(model.compose == state)
        #expect(model.notice == nil)

        // Past the moment it would have gone: nothing went, and nothing waits to go.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(model.outbox.isEmpty)
        #expect(model.notice == nil)
        model.go(to: .combined(.sent))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!model.visibleThreads.contains { $0.subject == "Quarter plan" })
        #expect(model.compose == state)
    }

    @Test func anUndoneReplyComesBackToItsConversation() async throws {
        let model = await model()
        let thread = try #require(model.visibleThreads.first)
        model.select(thread.id)
        model.startReply()
        var state = try #require(model.reply)
        state.draft.text = "Thursday works."
        model.queueSend(state, isReply: true)
        #expect(model.reply == nil)
        model.undo()
        #expect(model.reply == state)
        #expect(model.compose == nil)
    }

    @Test func anUndoneReplyOpensInTheComposerAfterMovingOn() async throws {
        let model = await model()
        let threads = model.visibleThreads
        try #require(threads.count > 1)
        model.select(threads[0].id)
        model.startReply()
        var state = try #require(model.reply)
        state.draft.text = "Thursday works."
        model.queueSend(state, isReply: true)
        model.select(threads[1].id)
        model.undo()
        // Still a reply to the first conversation, with everything as written.
        #expect(model.compose == state)
        #expect(model.compose?.draft.inReplyTo == state.draft.inReplyTo)
    }

    @Test func aMessageStartedMeanwhileIsKeptInDrafts() async throws {
        let model = await model(delay: 5)
        let first = try fullMessage(in: model)
        model.queueSend(first, isReply: false)
        model.startCompose()
        var second = try #require(model.compose)
        second.to = "ana@ledger.example"
        second.draft.subject = "Second thought"
        second.draft.text = "Started while the first was going."
        model.compose = second

        model.undo()
        #expect(model.compose == first)
        model.go(to: .combined(.drafts))
        try await waitFor { model.visibleThreads.contains { $0.subject == "Second thought" } }
    }

    @Test func theSendingNoticeTurnsIntoWhereItWentFrom() async throws {
        let model = await model()
        model.startCompose()
        var state = try #require(model.compose)
        state.to = "sam@kettle.example"
        state.draft.subject = "Hello"
        model.queueSend(state, isReply: false)
        let sending = try #require(model.notice)
        #expect(sending.countdown != nil && !sending.isSent && sending.canUndo)

        // One notice the whole way: never gone between "Sending…" and "Sent from …".
        for _ in 0..<300 {
            let notice = try #require(model.notice)
            if notice.isSent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = try #require(model.notice)
        #expect(sent.isSent && !sent.canUndo && sent.countdown == nil)
        #expect(sent.text.hasPrefix("Sent from"))
        // Too late to undo now: Undo does nothing to it.
        model.undo()
        #expect(model.compose == nil)
    }

    @Test func aMessageFromAnAliasSaysTheAlias() async throws {
        let model = await model()
        model.startCompose()
        var state = try #require(model.compose)
        state.to = "sam@kettle.example"
        state.draft.subject = "From sales"
        state.draft.from = EmailAddress(name: "Sales", address: "sales@kettle.example")
        model.queueSend(state, isReply: false)
        try await waitFor { model.notice?.isSent == true }
        #expect(model.notice?.text == "Sent from sales@kettle.example")
    }

    #if canImport(AppKit)
    @Test func theEditorStartsWithTheFormattingItWasSentWith() throws {
        let bold = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .boldFontMask)
        let written = NSMutableAttributedString(string: "Here it is", attributes: [.font: bold])
        written.append(NSAttributedString(string: ", bold and all.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        var draft = Draft(from: EmailAddress(address: "me@home.example"), text: written.string)
        draft.html = EmailHTMLWriter.write(written).html

        let start = try #require(EditorStart.formatted(draft))
        #expect(start.string == draft.text)
        let font = try #require(start.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))

        // A real message: paragraphs, blank lines, a link, a picture and a signature block.
        let body = NSMutableAttributedString(string: "Hi Sam,\n\nHere is ", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        body.append(NSAttributedString(string: "the plan", attributes: [.font: bold]))
        body.append(NSAttributedString(string: ", and the ", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        body.append(NSAttributedString(string: "notes", attributes: [.font: NSFont.systemFont(ofSize: 14),
                                                                     .link: URL(string: "https://example.com/notes")!]))
        body.append(NSAttributedString(string: ":\n", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        let picture = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let attachment = NSTextAttachment()
        attachment.image = picture
        body.append(NSAttributedString(attachment: attachment))
        body.append(NSAttributedString(string: "\n\nThanks!", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        let signature = NSAttributedString(string: "\n\nKaan\nRelevate", attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                                      EmailHTMLWriter.signatureKey: true])
        body.append(signature)
        let result = EmailHTMLWriter.write(body)
        var message = Draft(from: EmailAddress(address: "me@home.example"), text: body.string)
        message.html = result.html
        message.attachments = result.images
        #expect(!result.images.isEmpty)
        let restored = try #require(EditorStart.formatted(message))
        #expect(restored.string == message.text)
        let planAt = (restored.string as NSString).range(of: "the plan").location
        let planFont = try #require(restored.attribute(.font, at: planAt, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: planFont).contains(.boldFontMask))
        let notesAt = (restored.string as NSString).range(of: "notes").location
        #expect(restored.attribute(.link, at: notesAt, effectiveRange: nil) != nil)
        var pictures = 0
        restored.enumerateAttribute(.attachment, in: NSRange(location: 0, length: restored.length)) { value, _, _ in
            if value != nil { pictures += 1 }
        }
        #expect(pictures == 1)

        // Plain mail, or HTML that doesn't match the words, starts from the words.
        draft.html = nil
        #expect(EditorStart.formatted(draft) == nil)
        draft.html = "<div>Something else</div>"
        #expect(EditorStart.formatted(draft) == nil)
    }
    #endif
}
