import Foundation
import MailCore

/// How Ask answers: its length, the person's own instructions, which mail it looks through,
/// and whether it starts with suggested questions.
public struct AskPreferences: Codable, Equatable, Sendable {
    public enum Length: String, Codable, CaseIterable, Sendable {
        case brief, normal, detailed
        public var title: String {
            switch self {
            case .brief: String(localized: "Brief")
            case .normal: String(localized: "Normal")
            case .detailed: String(localized: "Detailed")
            }
        }
    }

    public var length = Length.normal
    /// In the person's own words ("Answer in Dutch", "Leave out newsletters").
    public var instructions = ""
    /// Only the mailbox in view, instead of every mailbox.
    public var onlyMailboxInView = false
    public var showsSuggestions = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        length = try values.decodeIfPresent(Length.self, forKey: .length) ?? .normal
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        onlyMailboxInView = try values.decodeIfPresent(Bool.self, forKey: .onlyMailboxInView) ?? false
        showsSuggestions = try values.decodeIfPresent(Bool.self, forKey: .showsSuggestions) ?? true
    }

    /// Added to what the assistant is told for each answer.
    var style: String {
        var lines: [String] = []
        switch length {
        case .brief: lines.append("Keep the answer under 40 words.")
        case .normal: break
        case .detailed: lines.append("The person likes fuller answers: up to 200 words when the question calls for it.")
        }
        let own = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { lines.append("Always follow these instructions from the person:\n" + own) }
        return lines.joined(separator: "\n")
    }
}

extension MailModel {
    public var askPreferences: AskPreferences {
        get {
            _ = priorityRevision
            return environment.defaults.data(forKey: "askPreferences").flatMap { try? JSONDecoder().decode(AskPreferences.self, from: $0) } ?? AskPreferences()
        }
        set { environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "askPreferences"); priorityRevision += 1 }
    }

    /// The conversations Ask may use, narrowed to the mailbox in view when the person asked for that.
    func askScope(_ threads: [MailThread]) -> [MailThread] {
        guard askPreferences.onlyMailboxInView, let account = place.accountID else { return threads }
        return threads.filter { $0.accountID == account }
    }
}

extension MailModel {
    /// A message in a language the system can't translate, translated by the assistant into the
    /// reader's language. Nil when there's no assistant or it fails.
    func translateWithAssistant(_ text: String, from language: Locale.Language) async -> String? {
        guard let intelligence else { return nil }
        let english = Locale(identifier: "en")
        let reader = Locale.preferredLanguages.first.flatMap { english.localizedString(forIdentifier: $0) } ?? "English"
        let source = language.languageCode.flatMap { english.localizedString(forLanguageCode: $0.identifier) } ?? "its language"
        return try? await intelligence.translate(text, from: source, to: reader)
    }
}
