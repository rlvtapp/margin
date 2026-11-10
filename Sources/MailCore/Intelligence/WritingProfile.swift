import Foundation
import NaturalLanguage

/// How someone writes email, learned from what they send, on this device. It grows with every
/// message: the greetings and sign-offs they use, how long their messages are, how casual they
/// sound, and the same per person they write to. Replies drafted by the assistant follow it.
///
/// People who write in more than one language get habits per language too: a Dutch "Hoi Noor,"
/// and an English "Hi Sam," are kept apart, and a reply follows the habits of the language the
/// conversation is in.
///
/// Learning is plain text analysis, not a language model: nothing leaves the device to build it.
public struct WritingProfile: Codable, Hashable, Sendable {
    /// How one person (or everyone) is usually written to.
    public struct Habits: Codable, Hashable, Sendable {
        /// Opening lines with the name taken out ("Hi {name},"), by how often they were used.
        public var greetings: [String: Int] = [:]
        /// Closing lines before the name ("Cheers", "Thanks!"), by how often they were used.
        public var signOffs: [String: Int] = [:]
        /// Words per message, newest last, at most 50 kept.
        public var lengths: [Int] = []
        public var messages = 0
        /// Messages with contractions (I'm, don't), exclamation marks, emoji.
        public var contractions = 0
        public var exclamations = 0
        public var emoji = 0
        /// Messages with an em or en dash used as punctuation (— or –).
        public var dashes = 0
        public var lastWritten: Date?

        public init() {}

        public var usualGreeting: String? { greetings.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key }
        public var usualSignOff: String? { signOffs.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key }
        /// The middle length of recent messages, in words.
        public var typicalLength: Int? {
            guard !lengths.isEmpty else { return nil }
            return lengths.sorted()[lengths.count / 2]
        }
        public var isCasual: Bool { messages > 0 && Double(contractions) / Double(messages) >= 0.4 }
        public var usesExclamations: Bool { messages > 0 && Double(exclamations) / Double(messages) >= 0.3 }
        public var usesEmoji: Bool { messages > 0 && Double(emoji) / Double(messages) >= 0.2 }
        /// Writes dashes as punctuation; most people typing email never do, and models overuse them.
        public var usesDashes: Bool { messages > 0 && Double(dashes) / Double(messages) >= 0.1 }

        mutating func add(_ sample: Sample, date: Date) {
            messages += 1
            if let greeting = sample.greeting { greetings[greeting, default: 0] += 1 }
            if let signOff = sample.signOff { signOffs[signOff, default: 0] += 1 }
            lengths.append(sample.words)
            if lengths.count > 50 { lengths.removeFirst(lengths.count - 50) }
            if sample.contractions { contractions += 1 }
            if sample.exclamation { exclamations += 1 }
            if sample.emoji { emoji += 1 }
            if sample.dash { dashes += 1 }
            lastWritten = max(lastWritten ?? date, date)
        }
    }

    public var overall = Habits()
    /// By language code ("en", "nl"), from what was written in it.
    public var languages: [String: Habits] = [:]
    /// By lowercased address.
    public var people: [String: Habits] = [:]
    /// By "language|address": how someone is written to in each language.
    public var peopleByLanguage: [String: Habits] = [:]
    /// Names for the people above, as last written to.
    public var names: [String: String] = [:]
    /// Message ids already learned from, so nothing counts twice.
    public var learned: Set<String> = []

    public init() {}

    public var isEmpty: Bool { overall.messages == 0 }

    /// Learns from one sent message. Quoted text and the signature are left out. Returns false
    /// when the message was already learned from or had nothing of the person's own writing.
    @discardableResult
    public mutating func learn(_ text: String, to recipients: [EmailAddress], signature: String? = nil,
                               id: String? = nil, date: Date = Date()) -> Bool {
        if let id, learned.contains(id) { return false }
        let own = Self.ownWriting(text, signature: signature)
        guard !own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let sample = Sample(own, recipient: recipients.first)
        let language = Self.language(of: own)
        overall.add(sample, date: date)
        if let language { languages[language, default: Habits()].add(sample, date: date) }
        // Per person only for one-to-one mail: a group message says less about one reader.
        if recipients.count == 1, let person = recipients.first {
            let key = person.address.lowercased()
            people[key, default: Habits()].add(sample, date: date)
            if let language { peopleByLanguage["\(language)|\(key)", default: Habits()].add(sample, date: date) }
            names[key] = person.displayName
        }
        if let id { learned.insert(id) }
        return true
    }

    public mutating func forget(_ address: String) {
        people[address.lowercased()] = nil
        names[address.lowercased()] = nil
        peopleByLanguage = peopleByLanguage.filter { !$0.key.hasSuffix("|" + address.lowercased()) }
    }

    /// The language a text is written in ("en", "nl"), when it's clear enough to tell.
    public static func language(of text: String) -> String? {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        guard words >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.5 else { return nil }
        return language.rawValue
    }

    /// The language most written to someone, or overall.
    public func usualLanguage(with recipient: EmailAddress?) -> String? {
        if let key = recipient?.address.lowercased() {
            let theirs = peopleByLanguage.filter { $0.key.hasSuffix("|" + key) }
            if let best = theirs.max(by: { $0.value.messages < $1.value.messages }) {
                return String(best.key.split(separator: "|").first ?? "")
            }
        }
        return languages.max { $0.value.messages < $1.value.messages }?.key
    }

    /// The people written to most, most first.
    public var frequentPeople: [(address: String, name: String, habits: Habits)] {
        people.map { ($0.key, names[$0.key] ?? $0.key, $0.value) }
            .sorted { $0.habits.messages == $1.habits.messages ? $0.name < $1.name : $0.habits.messages > $1.habits.messages }
    }

    /// Plain instructions for a model writing as this person to `recipient`, or nil when too
    /// little is known. `language` is the conversation's ("nl"); without it, the language most
    /// used with that person. Habits come from that language: the person's in it (two messages
    /// or more), else everyone's in it (three or more). A language with too little to go on gets
    /// only the general traits, never another language's greeting.
    public func styleGuide(for recipient: EmailAddress?, myName: String, language: String? = nil) -> String? {
        guard overall.messages >= 3 else { return nil }
        let key = recipient?.address.lowercased()
        let first = recipient.map { EmailAddress.firstName(of: $0) } ?? ""
        let lang = language ?? usualLanguage(with: recipient)
        let known = lang.flatMap { languages[$0] }.flatMap { $0.messages >= 3 ? $0 : nil }
        let personal: Habits? = {
            guard let key else { return nil }
            if let lang, let inLanguage = peopleByLanguage["\(lang)|\(key)"], inLanguage.messages >= 2 { return inLanguage }
            // Without a language to go by (older mail, very short notes), everything to them.
            if lang == nil || languages.isEmpty, let all = people[key], all.messages >= 2 { return all }
            return nil
        }()
        // Words like greetings only carry over within one language.
        let wording: Habits? = lang == nil || languages.isEmpty ? (personal ?? overall) : (personal ?? known)
        let tone = personal ?? known ?? overall
        var lines: [String] = []
        if let lang, !languages.isEmpty {
            let name = Locale(identifier: "en").localizedString(forLanguageCode: lang) ?? lang
            lines.append("Write in \(name), the language of this conversation.")
        }
        if let wording {
            if let greeting = wording.usualGreeting {
                lines.append("Open with \"\(Self.greeting(greeting, name: first))\".")
            } else {
                lines.append("Don't open with a greeting line; start with the point.")
            }
            if let signOff = wording.usualSignOff { lines.append("Sign off with \"\(signOff)\" and then \(myName).") }
        }
        if let length = tone.typicalLength {
            lines.append("Keep it about \(max(length, 8)) words, as \(myName) usually does.")
        }
        // Contractions are how casual English reads; other languages show it differently.
        if lang == nil || lang == "en" || languages.isEmpty {
            lines.append(tone.isCasual ? "Sound casual: use contractions like I'm and don't." : "Sound polished: avoid slang.")
        }
        if tone.usesExclamations { lines.append("An exclamation mark now and then is fine.") }
        if tone.usesEmoji { lines.append("An emoji is fine if it fits.") }
        if !tone.usesDashes { lines.append("Never use an em dash (—) or en dash (–). Use a comma or a full stop instead.") }
        let who = personal != nil ? " to \(recipient?.displayName ?? "")" : ""
        // Rules only, no sample emails: small models copy a sample's content into unrelated replies.
        return "Write the way \(myName) writes\(who):\n- " + lines.joined(separator: "\n- ")
    }

    /// "Hi {name}," with the name filled in, or without it ("Hi,") when there's no name.
    static func greeting(_ template: String, name: String) -> String {
        guard name.isEmpty else { return template.replacingOccurrences(of: "{name}", with: name) }
        return template.replacingOccurrences(of: " {name}", with: "").replacingOccurrences(of: "{name}", with: "")
    }

    /// Takes dashes out of a draft for someone who doesn't write them: " — " and "—" become a
    /// comma, a dash between words a space. Ranges like 9–5 are left alone.
    public static func withoutDashes(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s*[—–]\s*(?=[A-Za-zÀ-ÿ])"#, with: ", ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*—\s*"#, with: ", ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<=\D)\s+–\s+"#, with: ", ", options: .regularExpression)
        result = result.replacingOccurrences(of: #",\s*([,.!?])"#, with: "$1", options: .regularExpression)
        return result
    }

    /// Whether drafts should have dashes taken out: enough is known, and the person doesn't use them.
    public func avoidsDashes(language: String? = nil) -> Bool {
        let habits = language.flatMap { languages[$0] }.flatMap { $0.messages >= 3 ? $0 : nil } ?? overall
        return habits.messages >= 3 && !habits.usesDashes
    }

    // MARK: Reading a message

    /// What one message says about how it was written.
    struct Sample {
        var greeting: String?
        var signOff: String?
        var words: Int
        var contractions: Bool
        var exclamation: Bool
        var emoji: Bool
        var dash: Bool

        init(_ text: String, recipient: EmailAddress?) {
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            greeting = lines.first.flatMap { WritingProfile.greeting(in: $0, recipient: recipient) }
            signOff = WritingProfile.signOff(in: lines)
            words = text.split { $0.isWhitespace || $0.isNewline }.count
            contractions = text.range(of: #"\b\w+'(m|re|s|ve|ll|d|t)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                || text.contains("’")
            exclamation = text.contains("!")
            emoji = text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            dash = text.contains("—") || text.contains(" – ")
        }
    }

    /// Words that start a greeting line, in the languages Margin speaks.
    static let greetingWords = ["hi", "hey", "hello", "dear", "hiya", "morning", "good morning", "good afternoon",
                                "hoi", "hallo", "beste", "goedemorgen", "bonjour", "salut", "coucou", "こんにちは"]
    /// Lines that close a message before the name.
    static let signOffWords = ["thanks", "thank you", "thx", "cheers", "best", "best regards", "kind regards", "regards",
                               "all the best", "warmly", "talk soon", "speak soon", "see you", "love", "x", "xx", "groet",
                               "groetjes", "met vriendelijke groet", "bedankt", "dank je", "merci", "cordialement",
                               "bien à vous", "bonne journée", "à bientôt", "よろしくお願いします"]

    /// "Hi Noor," → "Hi {name},". Only short opening lines that start like a greeting count.
    static func greeting(in line: String, recipient: EmailAddress?) -> String? {
        let lower = line.lowercased()
        guard line.count <= 40, greetingWords.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ",") || lower.hasPrefix($0 + "!") }) else { return nil }
        var result = line
        if let recipient {
            for name in [recipient.displayName, EmailAddress.firstName(of: recipient)] where name.count > 1 {
                result = result.replacingOccurrences(of: name, with: "{name}", options: .caseInsensitive)
            }
        }
        return result
    }

    /// The closing line: one of the last three lines that matches a known sign-off.
    static func signOff(in lines: [String]) -> String? {
        for line in lines.suffix(3).reversed() {
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: ",.!-– "))
            if signOffWords.contains(cleaned.lowercased()) { return line.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
        }
        return nil
    }

    /// The person's own words: everything before quoted text, a "wrote:" line or a forwarded
    /// block, without their signature.
    public static func ownWriting(_ text: String, signature: String?) -> String {
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("---------- Forwarded") || trimmed == "-- " || trimmed == "--" { break }
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { break }
            if trimmed.hasPrefix("Op "), trimmed.hasSuffix("schreef:") { break }
            if trimmed.hasPrefix("Le "), trimmed.hasSuffix("a écrit :") || trimmed.hasSuffix("a écrit:") { break }
            kept.append(line)
        }
        var own = kept.joined(separator: "\n")
        if let signature = signature?.trimmingCharacters(in: .whitespacesAndNewlines), !signature.isEmpty {
            own = own.replacingOccurrences(of: signature, with: "")
        }
        return own.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension EmailAddress {
    /// "Noor Haddad" → "Noor"; an address without a name gives its local part.
    public static func firstName(of address: EmailAddress) -> String {
        address.displayName.split(separator: " ").first.map(String.init) ?? address.displayName
    }
}
