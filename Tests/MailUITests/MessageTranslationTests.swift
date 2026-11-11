import Foundation
import MailCore
import Testing
@testable import MailUI

@Suite struct MessageTranslationTests {
    @Test func findsTheLanguageOfAMessage() {
        let german = "Hallo Kaan, vielen Dank für deine Nachricht. Können wir uns nächste Woche treffen, um das Angebot zu besprechen?"
        #expect(MessageTranslation.language(of: german)?.languageCode?.identifier == "de")
        let english = "Hi Kaan, thanks for your message. Could we meet next week to talk through the offer and the timeline?"
        #expect(MessageTranslation.language(of: english)?.languageCode?.identifier == "en")
    }

    @Test func leavesShortTextAlone() {
        #expect(MessageTranslation.language(of: "Ok, top!") == nil)
        #expect(MessageTranslation.language(of: "") == nil)
    }

    @Test func offersOnlyLanguagesTheReaderDoesntRead() {
        let german = Locale.Language(identifier: "de")
        #expect(MessageTranslation.isForeign(german, readerLanguages: ["en-NL", "nl-NL"]))
        #expect(!MessageTranslation.isForeign(german, readerLanguages: ["en-US", "de-DE"]))
        #expect(!MessageTranslation.isForeign(Locale.Language(identifier: "nl"), readerLanguages: ["en-NL", "nl-NL"]))
    }

    @Test func keepsParagraphsAndShortLines() {
        let text = "Hallo Kaan,\n\nDanke!\nBis bald\n\nAnna"
        let pieces = MessageTranslation.pieces(text)
        #expect(pieces == [.text("Hallo Kaan,"), .breaks("\n\n"), .text("Danke!"), .breaks("\n"), .text("Bis bald"), .breaks("\n\n"), .text("Anna")])
        let back = MessageTranslation.join(pieces, translations: ["Hi Kaan,", "Thanks!", "See you soon", "Anna"])
        #expect(back == "Hi Kaan,\n\nThanks!\nSee you soon\n\nAnna")
    }

    @Test func joinsLinesWrappedAtAFixedWidth() {
        let wrapped = "Vielen Dank für die schnelle Antwort auf meine Frage von gestern\nAbend, das hilft uns sehr weiter."
        #expect(MessageTranslation.pieces(wrapped) == [.text("Vielen Dank für die schnelle Antwort auf meine Frage von gestern Abend, das hilft uns sehr weiter.")])
    }

    @Test func keepsTheOriginalWhereATranslationIsMissing() {
        let pieces = MessageTranslation.pieces("Eins\nZwei")
        #expect(MessageTranslation.join(pieces, translations: ["One"]) == "One\nZwei")
    }

    @MainActor @Test func translatesAWholeConversationAndBack() {
        let store = MessageTranslations()
        store.toggle(all: ["a", "b"])
        #expect(store.phase(of: "a") == .working && store.phase(of: "b") == .working)
        store.finish("a", with: "Hello")
        store.skip("b")  // already in the reader's language
        #expect(store.anyTranslated(["a", "b"]))
        store.toggle(all: ["a", "b"])
        #expect(store.phase(of: "a") == .original && !store.anyTranslated(["a", "b"]))
        // Asked again: the translation is still there, nothing to wait for.
        store.toggle("a")
        #expect(store.phase(of: "a") == .translated && store.translation(of: "a") == "Hello")
    }

    @MainActor @Test func aFailedTranslationCanBeTriedAgain() {
        let store = MessageTranslations()
        store.toggle("a")
        store.fail("a")
        store.toggle("a")
        #expect(store.phase(of: "a") == .working)
    }

    @Test func translatesHTMLInItsOwnLayout() {
        let html = """
        <html><head><title>Angebot</title><style>p { color: red; }</style></head>
        <body><p style="margin:0">Hallo <b>Kaan</b>,</p><!-- Kommentar --><script>var x = "Text";</script>
        <a href="https://example.com">Mehr lesen</a> &amp; www.example.com<br/>Fragen &amp; Antworten</body></html>
        """
        let segments = HTMLTranslation.segments(in: html)
        #expect(segments.map(\.text) == ["Hallo", "Kaan", ",", "Mehr lesen", "& www.example.com", "Fragen & Antworten"].filter { $0.contains(where: \.isLetter) })
        let result = HTMLTranslation.replacing(segments, in: html, with: ["Hello", "Kaan", "Read more", "& www.example.com", "Questions & answers"])
        #expect(result.contains("<p style=\"margin:0\">Hello <b>Kaan</b>,</p>"))
        #expect(result.contains(">Read more</a>"))
        #expect(result.contains("<br/>Questions &amp; answers</body>"))
        // Styles, scripts, the title and comments are as they were.
        #expect(result.contains("<title>Angebot</title><style>p { color: red; }</style>"))
        #expect(result.contains("<!-- Kommentar --><script>var x = \"Text\";</script>"))
    }

    @Test func leavesAddressesAndNumbersInHTMLAlone() {
        let segments = HTMLTranslation.segments(in: "<td>https://example.com/a</td><td>anna@example.com</td><td>12,50</td><td>Gesamt</td>")
        #expect(segments.map(\.text) == ["Gesamt"])
    }

    @MainActor @Test func showsTranslatedHTMLOnceItsReady() {
        let store = MessageTranslations()
        var safe = SafeHTMLCache.sanitized("<p>Hallo</p>"); safe.html = "<p>Hallo</p>"
        #expect(store.shown(safe, for: "a").html == "<p>Hallo</p>")
        store.toggle("a")
        store.progress("a", html: "<p>Hello</p>")
        #expect(store.shown(safe, for: "a").html == "<p>Hello</p>")
        store.finish("a", html: "<p>Hello</p>")
        store.toggle("a")
        #expect(store.shown(safe, for: "a").html == "<p>Hallo</p>")
    }

    @Test func leavesQuotedHistoryAlone() {
        let text = "Hallo Anna,\n\nPrima, bis Montag.\n\nOn Tue, 4 Nov 2026, Anna <anna@example.com> wrote:\n> Treffen wir uns am Montag?"
        let pieces = MessageTranslation.pieces(text)
        let texts = pieces.compactMap { piece -> String? in if case .text(let value) = piece { return value }; return nil }
        #expect(texts == ["Hallo Anna,", "Prima, bis Montag."])
        #expect(MessageTranslation.join(pieces, translations: ["Hi Anna,", "Great, see you Monday."])
                == "Hi Anna,\n\nGreat, see you Monday.\n\nOn Tue, 4 Nov 2026, Anna <anna@example.com> wrote:\n> Treffen wir uns am Montag?")
        let outlook = "Danke!\n\nVan: Anna\nVerzonden: dinsdag\nAan: Kaan\n\nTreffen wir uns?"
        #expect(MessageTranslation.quoteStart(in: outlook.components(separatedBy: "\n")) == 2)
    }

    @Test func leavesQuotedHTMLAloneButTranslatesForwards() {
        let reply = "<div>Prima, bis Montag.</div><blockquote type=\"cite\"><div>Treffen wir uns am Montag?</div></blockquote>"
        #expect(HTMLTranslation.segments(in: reply).map(\.text) == ["Prima, bis Montag."])
        let forward = "<div>Siehe unten</div><div class=\"gmail_quote\">---------- Forwarded message ---------<div>Das Angebot</div></div>"
        #expect(HTMLTranslation.segments(in: forward).map(\.text).contains("Das Angebot"))
    }
}
