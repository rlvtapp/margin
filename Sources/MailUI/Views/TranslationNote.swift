import MailCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Which messages are shown translated, kept on the model so the conversation's menu, a
/// message's own menu and the message itself agree, and a message scrolled away and back
/// doesn't translate again. Translations stay in memory only.
@MainActor @Observable
public final class MessageTranslations {
    public enum Phase: Sendable { case original, working, translated, failed }

    private(set) var phases: [String: Phase] = [:]
    private(set) var texts: [String: String] = [:]
    /// HTML mail translated in its own layout.
    private(set) var htmls: [String: String] = [:]
    /// The language each message is in, once looked at (nil inside: not clear, or the system
    /// can't translate from it).
    private(set) var languages: [String: Locale.Language?] = [:]
    /// Messages in a language the system can't translate, translated by the assistant instead,
    /// as plain text.
    private(set) var byAssistant: Set<String> = []

    public init() {}

    public func phase(of id: String) -> Phase { phases[id] ?? .original }
    func translation(of id: String) -> String? { texts[id] }
    func translatedHTML(of id: String) -> String? { htmls[id] }

    /// The HTML to show: translated when it's been asked for and is ready.
    public func shown(_ safe: SafeHTML, for id: String) -> SafeHTML {
        guard phase(of: id) == .translated || phase(of: id) == .working, let html = htmls[id] else { return safe }
        var translated = safe
        translated.html = html
        return translated
    }
    func language(of id: String) -> Locale.Language? { languages[id] ?? nil }
    func hasLooked(at id: String) -> Bool { languages[id] != nil }

    /// Translated, or back to the original.
    public func toggle(_ id: String) {
        switch phase(of: id) {
        case .translated: phases[id] = .original
        case .working: break
        case .original, .failed: phases[id] = texts[id] != nil || htmls[id] != nil ? .translated : .working
        }
    }

    /// The whole conversation: everything translated, or everything back to the original.
    public func toggle(all ids: [String]) {
        if anyTranslated(ids) {
            for id in ids where phase(of: id) != .original { phases[id] = .original }
        } else {
            for id in ids { phases[id] = texts[id] != nil || htmls[id] != nil ? .translated : .working }
        }
    }

    public func anyTranslated(_ ids: [String]) -> Bool {
        ids.contains { phase(of: $0) == .translated || phase(of: $0) == .working }
    }

    func noteLanguage(_ language: Locale.Language?, of id: String) { languages[id] = .some(language) }
    func noteAssistantNeeded(_ id: String) { byAssistant.insert(id) }
    func usesAssistant(_ id: String) -> Bool { byAssistant.contains(id) }
    func finish(_ id: String, with text: String) { texts[id] = text; phases[id] = .translated }
    func finish(_ id: String, html: String) { htmls[id] = html; phases[id] = .translated }
    /// Part of it translated, shown while the rest comes.
    func progress(_ id: String, text: String) { texts[id] = text }
    func progress(_ id: String, html: String) { htmls[id] = html }
    /// Translated, but not in the form now shown (plain text after HTML, or the other way): again.
    func retranslate(_ id: String) {
        texts[id] = nil
        htmls[id] = nil
        phases[id] = .working
    }
    func fail(_ id: String) { phases[id] = .failed }
    /// Nothing to translate (unclear language, or already the reader's): back to the original.
    func skip(_ id: String) { phases[id] = .original }
}

/// A message's text, translated in place when asked: the original view, or the translation as
/// plain text with its paragraphs, under a quiet line saying which it is.
struct TranslatableBody<Original: View>: View {
    let model: MailModel?
    let message: MailMessage
    let text: String?
    /// The HTML being shown (sanitized), translated in its own layout; nil when the text is.
    var html: String? = nil
    var textScale: Double = 1
    /// Space at the sides for the line and the translation, where the original draws its own.
    var inset: CGFloat = 0
    /// Leave the quoted earlier mail out of the translated text (it's folded away).
    var trimsQuote = false
    @ViewBuilder let original: () -> Original
    #if canImport(Translation)
    @State private var request: TranslationSession.Configuration?
    #endif

    private var store: MessageTranslations? { model?.translations }
    private var phase: MessageTranslations.Phase { store?.phase(of: message.id) ?? .original }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let store, let language = store.language(of: message.id), showsNote(language) {
                TranslationNote(language: language, isTranslated: phase == .translated, isWorking: phase == .working,
                                failed: phase == .failed) { store.toggle(message.id) }
                    .padding(.horizontal, inset)
            }
            if phase == .translated || phase == .working, html == nil || store?.usesAssistant(message.id) == true,
               let translated = store?.translation(of: message.id) {
                Text(PlainTextLinks.attributed(trimsQuote ? QuotedHistory.textWithoutQuote(translated) ?? translated : translated))
                    .font(.system(size: Look.size(15) * textScale))
                    .foregroundStyle(Ink.primary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                    .padding(.bottom, inset)
            } else {
                original()
            }
        }
        .animation(Motion.quick, value: phase)
        .onChange(of: html == nil, initial: true) { _, _ in
            // Shown as text after being translated as HTML, or the other way round.
            guard let store, phase == .translated else { return }
            if html != nil ? store.translatedHTML(of: message.id) == nil : store.translation(of: message.id) == nil {
                store.retranslate(message.id)
            }
        }
        #if canImport(Translation)
        .task(id: text?.count ?? -1) { await findLanguage() }
        .onChange(of: phase, initial: true) { _, now in if now == .working { start() } }
        .translationTask(request) { session in await translate(with: session) }
        #endif
    }

    /// The line shows for mail in a language the reader doesn't read (if they want it), and
    /// always once a translation has been asked for.
    private func showsNote(_ language: Locale.Language) -> Bool {
        if phase != .original { return true }
        return model?.offersTranslation != false && MessageTranslation.isForeign(language)
    }

    #if canImport(Translation)
    private func findLanguage() async {
        guard let store, let text, !text.isEmpty, !store.hasLooked(at: message.id) else { return }
        var found = MessageTranslation.language(of: text)
        var installed = false
        if let candidate = found {
            let status = await LanguageAvailability().status(from: candidate, to: nil)
            if status == .unsupported {
                // The system can't translate it; the assistant can, when there is one.
                if model?.isAssistantOn == true { store.noteAssistantNeeded(message.id) } else { found = nil }
            }
            installed = status == .installed
        }
        store.noteLanguage(found, of: message.id)
        if phase == .working {
            start()
        } else if installed, let found, model?.offersTranslation != false, MessageTranslation.isForeign(found) {
            // Likely to be translated: the system loads its model now, so Translate is quick.
            request = TranslationSession.Configuration(source: found, target: nil)
        }
    }

    private func start() {
        guard let store, store.hasLooked(at: message.id) else { return }  // starts once the language is known
        guard let language = store.language(of: message.id), MessageTranslation.isForeign(language, readerLanguages: Array(Locale.preferredLanguages.prefix(1))) else {
            store.skip(message.id)
            return
        }
        if store.usesAssistant(message.id) {
            translateWithAssistant(from: language)
            return
        }
        if request == nil {
            request = TranslationSession.Configuration(source: language, target: nil)
        } else {
            request?.invalidate()
        }
    }

    /// For a language the system can't translate: the assistant writes it in the reader's
    /// language, as plain text with its paragraphs.
    private func translateWithAssistant(from language: Locale.Language) {
        guard let store, let model, let text, !text.isEmpty else { store?.fail(message.id); return }
        let id = message.id
        Task {
            if let translated = await model.translateWithAssistant(text, from: language) {
                store.finish(id, with: translated)
            } else {
                store.fail(id)
            }
        }
    }

    private func translate(with session: TranslationSession) async {
        guard let store else { return }
        guard phase == .working else {
            nonisolated(unsafe) let session = session
            try? await session.prepareTranslation()
            return
        }
        if let html {
            let segments = HTMLTranslation.segments(in: html, keepsQuote: QuotedHistory.isForward(message.subject))
            // The same words (a repeated button, a footer line) are translated once.
            var unique: [String] = []
            var seen: Set<String> = []
            for segment in segments where seen.insert(segment.text).inserted { unique.append(segment.text) }
            do {
                func page(_ translated: [String]) -> String {
                    let byText = Dictionary(zip(unique, translated), uniquingKeysWith: { first, _ in first })
                    return HTMLTranslation.replacing(segments, in: html, with: segments.map { byText[$0.text] ?? $0.text })
                }
                // The page reloads with each update, so only once on the way: when the top is done.
                let translated = try await Self.translations(of: unique, with: session, updates: 1) { partial in
                    store.progress(message.id, html: page(partial))
                }
                store.finish(message.id, html: page(translated))
            } catch {
                store.fail(message.id)
            }
            return
        }
        guard let text else { return }
        let pieces = MessageTranslation.pieces(text, keepsQuote: QuotedHistory.isForward(message.subject))
        let texts = pieces.compactMap { piece -> String? in
            if case .text(let value) = piece { return value }
            return nil
        }
        do {
            let translated = try await Self.translations(of: texts, with: session, updates: .max) { partial in
                store.progress(message.id, text: MessageTranslation.join(pieces, translations: partial))
            }
            store.finish(message.id, with: MessageTranslation.join(pieces, translations: translated))
        } catch {
            store.fail(message.id)
        }
    }

    /// Each text in the reader's language, in the same order. As they come in, `update` gets
    /// what's done so far (the rest still in the original): first once the opening part is
    /// done, then every half second, at most `updates` times. The session is only ever used
    /// from this one task, so handing it to the translation call is safe.
    private static func translations(of texts: [String], with session: TranslationSession, updates: Int,
                                     update: ([String]) -> Void) async throws -> [String] {
        nonisolated(unsafe) let session = session
        nonisolated(unsafe) let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        nonisolated(unsafe) let responses = session.translate(batch: requests)
        var translated = texts
        var done: Set<Int> = []
        var sent = 0
        var lastSent = ContinuousClock.now
        let opening = Set(0..<min(texts.count, 12))
        for try await response in responses {
            guard let index = response.clientIdentifier.flatMap(Int.init), translated.indices.contains(index) else { continue }
            translated[index] = response.targetText
            done.insert(index)
            guard sent < updates, done.count < texts.count else { continue }
            let due = sent == 0 ? opening.isSubset(of: done) : ContinuousClock.now - lastSent > .milliseconds(500)
            if due {
                update(translated)
                sent += 1
                lastSent = .now
            }
        }
        return translated
    }
    #endif
}

/// Above a message in another language: one quiet line, like the one for pictures. "Written in
/// German · Translate", then "Translated from German · Show original".
struct TranslationNote: View {
    let language: Locale.Language
    let isTranslated: Bool
    let isWorking: Bool
    let failed: Bool
    let toggle: () -> Void

    private var name: String { MessageTranslation.name(of: language) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "translate").font(.system(size: Look.size(11)))
            Group {
                if failed {
                    Text("Couldn't translate from \(name)")
                } else if isTranslated {
                    Text("Translated from \(name)")
                } else {
                    Text("Written in \(name)")
                }
            }
            .lineLimit(1)
            Text(verbatim: "·").foregroundStyle(Ink.quaternary)
            ZStack(alignment: .leading) {
                // The longest label keeps its room, so the line doesn't shift as it changes.
                Text("Show original").fontWeight(.medium).hidden()
                if isWorking {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Translating…")
                    }
                } else {
                    Button(isTranslated ? "Show original" : (failed ? "Try Again" : "Translate"), action: toggle)
                        .buttonStyle(.plain)
                        .fontWeight(.medium)
                        .foregroundStyle(Ink.primary)
                }
            }
        }
        .font(TypeScale.label)
        .foregroundStyle(Ink.tertiary)
    }
}
