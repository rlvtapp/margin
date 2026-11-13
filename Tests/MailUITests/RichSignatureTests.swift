import Foundation
#if canImport(AppKit)
import AppKit
#endif
import MailCore
import Testing
@testable import MailUI

/// Signatures with formatting and pictures: written in the message editor, shown that way while
/// writing, and sent as shown.
@MainActor @Suite struct RichSignatureTests {
    let logo = OutgoingAttachment(filename: "picture-1.png", mimeType: "image/png", data: Data([1, 2, 3]),
                                  contentID: "picture-abc@margin-inline")

    func account() -> MailAccount {
        var account = MailAccount.sample
        account.signature = "Alex"
        account.aliases = [EmailAddress(address: "sales@northwind.example"), EmailAddress(address: "help@northwind.example")]
        account.moreSignatures = [NamedSignature(name: "Logo", text: "\u{FFFC}\nAlex Rivera\nNorthwind",
                                                 html: "<div><img src=\"cid:picture-abc@margin-inline\"><b>Alex Rivera</b></div>",
                                                 pictures: [logo], rich: Data([0]))]
        return account
    }

    @Test func theWordsLeaveThePicturesOut() {
        let signature = NamedSignature(name: "A", text: "\u{FFFC}\nAlex Rivera\nCall me \u{FFFC}")
        #expect(signature.plainText == "Alex Rivera\nCall me")
        #expect(NamedSignature(name: "B", text: "Alex").plainText == "Alex")
    }

    @Test func thePreviewShowsItsPictures() throws {
        let preview = try #require(account().moreSignatures?.first?.previewHTML)
        #expect(preview.contains("data:image/png;base64,AQID"))
        #expect(!preview.contains("cid:"))
    }

    @Test func theDefaultKeepsItsFormattingAndCanBeEmptied() {
        var account = account()
        account.setSignature(NamedSignature(name: NamedSignature.defaultName, text: "Alex R.", html: "<i>Alex R.</i>",
                                            pictures: [logo], rich: Data([1])))
        #expect(account.signature == "Alex R." && account.signatureHTML == "<i>Alex R.</i>")
        #expect(account.defaultSignature?.pictures == [logo] && account.defaultSignature?.rich == Data([1]))
        account.setSignature(NamedSignature(name: NamedSignature.defaultName, text: " "))
        #expect(account.signature == nil && account.signatureHTML == nil && account.signaturePictures == nil && account.signatureRich == nil)
    }

    @Test func anAddressCanUseOneOfTheMailboxSignatures() {
        var account = account()
        account.aliasSignatureNames = ["sales@northwind.example": "Logo", "help@northwind.example": ""]
        #expect(account.signatureChoice(sendingAs: EmailAddress(address: "Sales@northwind.example"), forReply: false)?.name == "Logo")
        #expect(account.signatureChoice(sendingAs: EmailAddress(address: "help@northwind.example"), forReply: false) == nil)
        #expect(account.signature(sendingAs: account.address, forReply: false) == "Alex")
        // Switching From brings the address's own signature along, and back.
        var state = ComposeState(account: account)
        state.send(from: account, previous: account, as: EmailAddress(address: "sales@northwind.example"))
        #expect(state.signatureInUse?.name == "Logo")
        state.send(from: account, previous: account, as: EmailAddress(address: "help@northwind.example"))
        #expect(state.signatureInUse == nil && state.draft.text.isEmpty)
    }

    @Test func swappingToAFormattedSignatureKeepsWhatWasWritten() throws {
        let account = account()
        var state = ComposeState(account: account)
        state.draft.text = "Hi!" + state.draft.text
        let logo = try #require(account.moreSignatures?.first)
        state.useSignature(logo)
        #if os(macOS)
        // The Mac's editor shows it with its picture, so the text has the picture's place.
        #expect(state.draft.text == "Hi!\n\n\u{FFFC}\nAlex Rivera\nNorthwind")
        #else
        #expect(state.draft.text == "Hi!\n\nAlex Rivera\nNorthwind")
        #endif
        #expect(state.signatureInUse == logo)
        #expect(state.hasContent)
        state.useSignature(account.defaultSignature)
        #expect(state.draft.text == "Hi!\n\nAlex")
    }

    @Test func renamingASignatureKeepsWhatUsesIt() {
        var account = account()
        account.replySignature = "Logo"
        account.aliasSignatureNames = ["sales@northwind.example": "Logo"]
        var renamed = account.moreSignatures![0]
        renamed.name = "Brand"
        account.saveSignature(renamed, replacing: "Logo")
        #expect(account.moreSignatures?.map(\.name) == ["Brand"])
        #expect(account.replySignature == "Brand" && account.aliasSignatureNames?["sales@northwind.example"] == "Brand")
        // Removing it puts replies and the address back on the default.
        account.removeSignature(named: "Brand")
        #expect(account.moreSignatures == nil && account.replySignature == nil && account.aliasSignatureNames == nil)
        // The default is emptied rather than removed.
        account.removeSignature(named: NamedSignature.defaultName)
        #expect(account.signature == nil)
    }

    @Test func aSignatureCopiesToAnotherInbox() {
        let work = account()
        var personal = MailAccount.samplePersonal
        personal.signature = "A."
        let logo = work.moreSignatures![0]
        // Next to its others, under a free name; the default is named after its inbox.
        personal.copySignature(logo, from: work.label, asDefault: false)
        personal.copySignature(logo, from: work.label, asDefault: false)
        personal.copySignature(work.defaultSignature!, from: work.label, asDefault: false)
        #expect(personal.moreSignatures?.map(\.name) == ["Logo", "Logo 2", "Work"])
        #expect(personal.moreSignatures?.first?.pictures == [self.logo] && personal.signature == "A.")
        // Or as its default, formatting and pictures included.
        personal.copySignature(logo, from: work.label, asDefault: true)
        #expect(personal.defaultSignature?.html == logo.html && personal.signaturePictures == [self.logo])
        #expect(personal.defaultSignature?.name == NamedSignature.defaultName)
    }

    @Test func theSignaturesPageSavesAndCopies() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let work = try #require(model.accounts.first), personal = try #require(model.accounts.dropFirst().first)
        model.changeSignatures(of: .account(work.id)) { $0.saveSignature(NamedSignature(name: "Short", text: "– A"), replacing: nil) }
        model.copySignature(NamedSignature(name: "Short", text: "– A"), from: .account(work.id), to: .account(personal.id), asDefault: true)
        #expect(model.account(work.id)?.moreSignatures?.map(\.name) == ["Short"])
        #expect(model.account(personal.id)?.signature == "– A")
        #expect(SettingsPage.signatures.matches("logo") && SettingsPage.sections.joined().contains(.signatures))
    }

    @Test func inboxesWithoutTheirOwnUseTheSharedSignatures() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        let work = try #require(model.accounts.first), personal = try #require(model.accounts.dropFirst().first)
        model.changeSignatures(of: .account(work.id)) { $0.removeSignature(named: NamedSignature.defaultName) }
        model.changeSignatures(of: .account(personal.id)) { $0.removeSignature(named: NamedSignature.defaultName) }

        // One for every inbox.
        model.changeSignatures(of: .all) { $0.saveSignature(NamedSignature(name: "x", text: "For everyone"), replacing: NamedSignature.defaultName) }
        #expect(ComposeState(account: try #require(model.account(work.id))).draft.text == "\n\nFor everyone")
        #expect(ComposeState(account: try #require(model.account(personal.id))).draft.text == "\n\nFor everyone")

        // A workspace's comes first for its inboxes.
        model.workspaces = [Workspace(name: "Studio", colorIndex: 1, accounts: [work.id])]
        let studio = try #require(model.workspaces.first)
        model.changeSignatures(of: .workspace(studio.id)) { $0.saveSignature(NamedSignature(name: "x", text: "Alex · Studio"), replacing: NamedSignature.defaultName) }
        #expect(ComposeState(account: try #require(model.account(work.id))).draft.text == "\n\nAlex · Studio")
        #expect(model.account(work.id)?.inheritedSignatures?.title == "Studio")
        #expect(ComposeState(account: try #require(model.account(personal.id))).draft.text == "\n\nFor everyone")

        // An inbox's own wins; the shared one is still in the menu, named after where it's from.
        model.changeSignatures(of: .account(personal.id)) { $0.saveSignature(NamedSignature(name: "x", text: "A."), replacing: NamedSignature.defaultName) }
        let mine = try #require(model.account(personal.id))
        #expect(ComposeState(account: mine).draft.text == "\n\nA.")
        #expect(mine.availableSignatures.map(\.name) == [NamedSignature.defaultName, "All inboxes"])

        // And an inbox can do without them.
        model.changeSignatures(of: .account(work.id)) { set in
            guard var mailbox = set as? MailAccount else { return }
            mailbox.usesSharedSignatures = false
            set = mailbox
        }
        #expect(ComposeState(account: try #require(model.account(work.id))).draft.text.isEmpty)

        // The shared ones are never saved with a mailbox, and don't make it look changed.
        let saved = try JSONEncoder().encode(try #require(model.account(personal.id)))
        #expect(!(String(data: saved, encoding: .utf8) ?? "").contains("For everyone"))
        #expect(!(String(data: saved, encoding: .utf8) ?? "").contains("sharedSignatures"))
        let reloaded = try JSONDecoder().decode(MailAccount.self, from: saved)
        #expect(reloaded.sharedSignatures.value == nil && reloaded == model.account(personal.id))
        model.workspaces = []
        model.sharedSignatureSets = [:]
    }

    @Test func sendingAddsTheSignaturesPictures() {
        var draft = Draft(from: EmailAddress(address: "alex@northwind.example"), text: "Hi\n\nAlex Rivera")
        draft = MailModel.withFormattedSignature(draft, plain: "\n\nAlex Rivera", html: "<img src=\"cid:picture-abc@margin-inline\">",
                                                 pictures: [logo])
        #expect(draft.html?.contains("class=\"margin-signature\"") == true)
        #expect(draft.attachments.map(\.contentID) == [logo.contentID])
    }

    #if canImport(AppKit)
    func picture() -> NSImage {
        NSImage(size: NSSize(width: 400, height: 100), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
    }

    func written() -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = picture()
        attachment.bounds = CGRect(x: 0, y: 0, width: 120, height: 30)
        let text = NSMutableAttributedString(string: "\n", attributes: SignatureText.normal())
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "\n", attributes: SignatureText.normal()))
        text.append(NSAttributedString(string: "Alex Rivera", attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "\nnorthwind.example  \n", attributes: SignatureText.normal().merging([.link: URL(string: "https://northwind.example")!]) { $1 }))
        return text
    }

    @Test func aWrittenSignatureKeepsItsLookAndPictures() throws {
        let signature = SignatureText.signature(named: "Logo", from: written())
        // Trimmed, with the picture's place in the words.
        #expect(signature.text == "\u{FFFC}\nAlex Rivera\nnorthwind.example")
        #expect(signature.plainText == "Alex Rivera\nnorthwind.example")
        let html = try #require(signature.html)
        #expect(html.contains("<b>Alex Rivera</b>") && html.contains("https://northwind.example"))
        let picture = try #require(signature.pictures?.only)
        #expect(html.contains("cid:\(picture.contentID ?? "-")") && html.contains("width=\"120\""))
        #expect(signature.rich != nil)

        // Back in the editor: the same words, the picture at its size, the name still bold.
        let shown = SignatureText.attributed(signature)
        #expect(shown.string == signature.text)
        let attachment = try #require(shown.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width == 120 && attachment.image != nil)
        let font = try #require(shown.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        // The normal colour still follows dark mode.
        #expect(shown.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .labelColor)
    }

    @Test func plainWordsMakeAPlainSignature() {
        let signature = SignatureText.signature(named: "Short", from: NSAttributedString(string: "  – A\n", attributes: SignatureText.normal()))
        #expect(signature == NamedSignature(name: "Short", text: "– A"))
    }

    @Test func theMessageShowsTheSignatureAsItIsSent() throws {
        let signature = SignatureText.signature(named: "Logo", from: written())
        let view = NSTextView()
        view.string = "Hi!\n\n" + signature.text + "\n\nSent from Margin"
        #expect(RichTextEditor.showSignature(signature, in: view))
        // Only the formatting changed: the words are what the composer holds.
        #expect(view.string == "Hi!\n\n" + signature.text + "\n\nSent from Margin")
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.attachment, at: 5, effectiveRange: nil) is NSTextAttachment)
        let written = EmailHTMLWriter.write(storage)
        #expect(written.images.count == 1)
        // One block for the signature, so sending doesn't add it again; the line under it stays out.
        let html = written.html
        let open = try #require(html.range(of: "<div class=\"margin-signature\">"))
        #expect(html.components(separatedBy: "margin-signature").count == 2)
        #expect(html[open.upperBound...].contains("Alex Rivera"))
        #expect(!html[..<open.lowerBound].contains("Alex Rivera"))
        let close = try #require(html.range(of: "</div>\n<div", range: html.range(of: "northwind.example</a>")!.upperBound..<html.endIndex))
        #expect(html[close.upperBound...].contains("Sent from Margin"))
    }

    @Test func aSignatureWrittenAsHTMLReadsIntoTheEditor() throws {
        let made = SignatureTools.make(.init(name: "Alex Rivera", role: "Designer", company: "Northwind", website: "northwind.example"))
        let read = try #require(SignatureText.fromHTML(made.html))
        #expect(read.string == made.text)
        // The near-black name becomes the normal colour, and its semibold reads as bold.
        #expect(read.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor)
        let font = try #require(read.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let signature = SignatureText.signature(named: NamedSignature.defaultName, from: read)
        #expect(signature.html?.contains("<b>Alex Rivera</b>") == true && signature.rich != nil)
    }

    @Test func picturesAreKeptSmall() {
        let big = NSImage(size: NSSize(width: 3000, height: 1000), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        #expect(SignatureText.smaller(big, shownAt: 300).size.width == 600)
        #expect(SignatureText.smaller(picture(), shownAt: 300).size.width == 400)
    }
    #endif
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
