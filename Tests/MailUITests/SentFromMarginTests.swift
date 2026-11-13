import Foundation
#if canImport(AppKit)
import AppKit
#endif
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct SentFromMarginTests {
    let me = EmailAddress(name: "Kaan", address: "kaan@studio.example")

    #if canImport(AppKit)
    @Test func theEditorShowsMarginAsTheLinkItIsSentAs() throws {
        let view = NSTextView()
        view.string = "Tot dan!\n\nKaan\n\nSent from Margin"
        #expect(RichTextEditor.linkLastLine("Sent from Margin", in: view))
        let storage = try #require(view.textStorage)
        let margin = (view.string as NSString).range(of: "Margin", options: .backwards)
        #expect((storage.attribute(.link, at: margin.location, effectiveRange: nil) as? URL)?.absoluteString == "https://margin.relevate.app")
        #expect(storage.attribute(.link, at: margin.location - 2, effectiveRange: nil) == nil)
        // What's sent is what the editor holds: the link is in its formatted version.
        #expect(RichTextController.html(from: storage)?.contains("https://margin.relevate.app") == true)
        // Deleted or changed: nothing to link.
        view.string = "Tot dan!"
        #expect(!RichTextEditor.linkLastLine("Sent from Margin", in: view))
        // Words without "Margin" link as a whole.
        #expect(MailModel.linkRange(in: "Typed fast") == "Typed fast".startIndex..<"Typed fast".endIndex)
    }
    #endif

    @Test func aFormattedSignatureStillWorksWithTheLineUnderIt() {
        var draft = Draft(from: me, text: "Hi\n\nAlex\n\nSent from Margin")
        draft = MailModel.withFormattedSignature(draft, plain: "\n\nAlex", html: "<b>Alex</b>", after: "\n\nSent from Margin")
        let html = draft.html ?? ""
        #expect(html.contains("<b>Alex</b>") && html.hasSuffix("<div><br>Sent from Margin</div>"))
        // Sending changes nothing else: the text is as written.
        #expect(draft.text == "Hi\n\nAlex\n\nSent from Margin")
    }

    @Test func aNewMessageShowsIt() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.startCompose()
        let state = try #require(model.compose)
        // In the text from the start, under the signature, so it can be seen and deleted.
        #expect(state.draft.text.hasSuffix("\n\nSent from Margin"))
        #expect(!state.hasContent)

        // Changing the words, or turning it off, applies to the next message.
        model.sentFromMarginText = "Getypt in Margin"
        model.startCompose()
        #expect(model.compose?.draft.text.hasSuffix("Getypt in Margin") == true)
        model.addsSentFromMargin = false
        model.startCompose()
        #expect(model.compose?.draft.text.contains("Margin") == false)
    }

    @Test func switchingMailboxKeepsItLast() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        var state = ComposeState(account: try #require(model.accounts.first))
        state.use(signature: nil)
        state.use(signature: "Kaan\nStudio North")
        state.addSentFrom("Sent from Margin")
        state.use(signature: "Kaan")
        #expect(state.draft.text == "\n\nKaan\n\nSent from Margin")
    }
}
