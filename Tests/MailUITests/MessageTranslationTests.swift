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

    /// A product changelog as its plain-text part comes: a headline, the product's name, a
    /// divider, short bullets full of product names, links and a street address. The recognizer
    /// reads only about its first hundred characters, and on their own those read as Indonesian.
    static let changelog = """
        Changelog 82 plus Lumen Docs search is now built on Lumen

        Lumen

        --------------
        Lumen Changelog
        --------------

        * HIPAA support for Lumen's backend services
        * Managed Auth adds passkey and single sign-on
        * Drag and drop uploads for Object Storage
        * A new model is now available in the Lumen AI Gateway

        Read the full Changelog ( https://lumen.example.com/docs/changelog )

        In case you missed it...

        * Lumen Docs search is now built on Lumen ( https://lumen.example.com/blog/docs-search )
        * Building data pipelines with the Lumen backend ( https://lumen.example.com/blog/data-pipelines )

        Lumen LLC, 160 Spear Street, 15th Floor San Francisco, CA 94105 - Unsubscribe ( https://track.example.com/unsubscribe/dgT7swoDALvwDLrwDAGhjmEDRt5Yyy-rZtN5WrA= )
        """

    @Test func anEnglishChangelogIsEnglish() {
        let reader = ["en-NL", "nl-NL"]
        #expect(MessageTranslation.language(of: Self.changelog, readerLanguages: reader)?.languageCode?.identifier == "en")
        // Someone who doesn't read English still gets it as English, to translate.
        #expect(MessageTranslation.language(of: Self.changelog, readerLanguages: ["de-DE"])?.languageCode?.identifier == "en")
    }

    @Test func englishBetweenTrackingLinksIsEnglish() {
        let newsletter = """
            Lumen Changelog
            https://link.mail.example.com/ss/c/u001.Xq9mZ0aWfKz3dHkTnPq8sLw2bY5vRcEjU7hGtD4iMoN6pA1yBxCzV/4dk/aB3cD9eFgHiJkLmN/h0/h001.QwErTyUiOpAsDfGhJkLzXcVbNm

            Lumen Changelog | Nov 13, 2026

            * Version 18 support is now generally available
              https://lumen.example.com/docs/changelog?utm_source=newsletter&utm_medium=email&utm_campaign=changelog-2026-11-13
            * Branch restore now keeps your compute settings
            * Lumen Auth: a new SDK for web apps
            * Lumen MCP server adds query_stats tools
            * Console: faster SQL Editor, dark mode tweaks

            Read the full Changelog
            https://link.mail.example.com/ss/c/u001.ZxCvBnMaSdFgHjKlQwErTyUiOp1234567890abcdefGHIJ/4dk/QwErT/h1/h001.AsDfGhJkL

            In case you missed it…
            * How we scaled logical replication
              https://link.mail.example.com/ss/c/u001.LkJhGfDsAPoIuYtReWqMnBvCxZ/4dk/yy/h3/h001.Lkjhg

            Lumen, Inc. 2261 Market Street #4521, San Francisco, CA 94114
            Unsubscribe https://link.mail.example.com/ss/c/u001.unsub123ABCdefGHI/4dk/xx/h4/h001.Unsub
            """
        #expect(MessageTranslation.language(of: newsletter, readerLanguages: ["en-US"])?.languageCode?.identifier == "en")
    }

    @Test func mailInAnotherLanguageIsStillFound() {
        let reader = ["en-NL", "nl-NL"]
        // A newsletter with English product names, links and an address, in German.
        let german = """
            Lumen Plus Update

            -----------------
            Neuigkeiten im November
            -----------------

            * Checkout Extensibility ist jetzt für alle Händler verfügbar
            * Neue Berichte im Analytics Dashboard zeigen Umsätze pro Kanal
            * Lumen Flow kann jetzt Bestellungen automatisch markieren

            Alle Neuigkeiten lesen ( https://click.mail.example.com/ls/click?upn=u001.abcDEF123-2Fxyz )

            Lumen International Ltd., Victoria Buildings, 1-2 Haddington Road, Dublin 4, Irland
            Abmelden ( https://click.mail.example.com/unsub?u=abc123 )
            """
        let indonesian = """
            Halo Kaan,

            Terima kasih sudah mendaftar. Kami akan mengirimkan kabar terbaru tentang produk dan promo menarik setiap minggu. \
            Jika kamu punya pertanyaan, balas saja email ini dan tim kami akan membantu.

            Salam hangat,
            Tim Dukungan
            """
        let spanish = """
            Lumen Newsletter

            Novedades de noviembre

            * Lumen AI ahora puede buscar en tus documentos y calendarios
            * Las bases de datos cargan el doble de rápido
            * Nuevas plantillas para equipos de producto

            Leer más ( https://lumen.example.com/es/releases?utm_source=email&utm_medium=newsletter )

            Lumen Labs, Inc., 2300 Harrison Street, San Francisco, CA 94110
            Cancelar suscripción
            """
        let japanese = "山田様\n\nいつもお世話になっております。来週の打ち合わせの件で、ご都合の良い日時を教えていただけますでしょうか。資料は事前にお送りいたします。\n\nよろしくお願いいたします。"
        let russian = "Здравствуйте, Каан!\n\nСпасибо за ваше письмо. Мы рассмотрели ваш запрос и готовы предложить встречу на следующей неделе. Пожалуйста, сообщите, какое время вам удобно."
        for (text, code) in [(german, "de"), (indonesian, "id"), (spanish, "es"), (japanese, "ja"), (russian, "ru")] {
            let found = MessageTranslation.language(of: text, readerLanguages: reader)
            #expect(found?.languageCode?.identifier == code)
            #expect(found.map { MessageTranslation.isForeign($0, readerLanguages: reader) } == true)
        }
    }

    @Test func aLanguageTheReaderReadsWinsWithAFairShare() {
        // Mostly Dutch with an English quote in it: for someone who reads Dutch, it's Dutch.
        let mixed = """
            Hoi Kaan, je hebt een nieuw bod ontvangen op je advertentie. Bekijk het bod en reageer snel, dan weet de koper waar hij aan toe is.
            The buyer wrote: is it still available and can you ship it this week?
            """
        #expect(MessageTranslation.language(of: mixed, readerLanguages: ["nl-NL"])?.languageCode?.identifier == "nl")
    }

    @Test func looksOnlyAtWords() {
        let words = MessageTranslation.readableWords(in: """
            Read the full Changelog ( https://lumen.example.com/docs ) or mail team@lumen.example.com
            HIPAA, MCP and CA 94105 on 15th Floor; LumenHub dgT7swoDALvwDLrwDAGhjmEDRt5Yyy-rZtN5WrA= utm_source=x a/b I
            > Quoted earlier mail stays out
            """).map(\.text)
        #expect(words == ["Read", "the", "full", "Changelog", "or", "mail", "and", "on", "Floor", "I"])
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
