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
        /// Words per sentence, the middle of each message, newest last, at most 50 kept.
        public var sentenceLengths: [Int] = []
        /// Paragraphs per message, newest last, at most 50 kept.
        public var paragraphCounts: [Int] = []
        /// Messages that address the reader formally (u, Sie, vous, usted) or informally (je, du, tu, tú).
        public var formal = 0
        public var informal = 0
        /// Messages written in lower case.
        public var lowercase = 0
        /// Phrases of three or four words, by how many messages used them. Kept for everyone and
        /// per language, not per person.
        public var phrases: [String: Int] = [:]
        /// How the first sentence after the greeting starts ("Thanks for …"), by how often.
        public var openers: [String: Int] = [:]
        /// The last sentence before the sign-off ("Let me know if you have questions."), by how often.
        public var closers: [String: Int] = [:]
        /// The name under the sign-off ("Kaan"), by how often: what to sign with, which can
        /// differ from a mailbox's display name.
        public var signedNames: [String: Int] = [:]

        public init() {}

        public var usualGreeting: String? { greetings.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key }
        public var usualSignOff: String? { signOffs.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key }
        public var usualSignedName: String? {
            signedNames.filter { $0.value >= 2 }.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        }
        /// The middle length of recent messages, in words.
        public var typicalLength: Int? { Self.middle(lengths) }
        /// The middle sentence length of recent messages, in words.
        public var typicalSentence: Int? { Self.middle(sentenceLengths) }
        /// The usual number of paragraphs.
        public var typicalParagraphs: Int? { Self.middle(paragraphCounts) }
        public var isCasual: Bool { messages > 0 && Double(contractions) / Double(messages) >= 0.4 }
        public var usesExclamations: Bool { messages > 0 && Double(exclamations) / Double(messages) >= 0.3 }
        public var usesEmoji: Bool { messages > 0 && Double(emoji) / Double(messages) >= 0.2 }
        /// Writes dashes as punctuation; most people typing email never do, and models overuse them.
        public var usesDashes: Bool { messages > 0 && Double(dashes) / Double(messages) >= 0.1 }
        /// True for formal address, false for informal, nil when it's not clear (or the language has no such choice).
        public var addressesFormally: Bool? {
            let total = formal + informal
            guard total >= 2 else { return nil }
            if Double(formal) / Double(total) >= 0.7 { return true }
            if Double(informal) / Double(total) >= 0.7 { return false }
            return nil
        }
        public var writesLowercase: Bool { messages >= 3 && Double(lowercase) / Double(messages) >= 0.6 }

        /// The phrases used in enough messages to be a habit, most used first, without ones that
        /// are only part of a longer habit.
        public var habitualPhrases: [String] {
            let junk = ["outlook", "iphone", "ipad", "android", "ios", "sent from", "verzonden", "verstuurd", "gesendet",
                        "vriendelijke groet", "kind regards", "best regards"]
            return Self.habitual(phrases.filter { entry in !junk.contains { entry.key.contains($0) } }, messages: messages, limit: 8, dropsParts: true)
        }
        public var habitualOpeners: [String] { Self.habitual(openers, messages: messages, limit: 3) }
        public var habitualClosers: [String] { Self.habitual(closers, messages: messages, limit: 3) }

        static func middle(_ values: [Int]) -> Int? {
            values.isEmpty ? nil : values.sorted()[values.count / 2]
        }

        /// Used in at least 3 messages and one in ten.
        static func habitual(_ counts: [String: Int], messages: Int, limit: Int, dropsParts: Bool = false) -> [String] {
            let needed = max(3, Int((Double(messages) * 0.1).rounded(.up)))
            var picked = counts.filter { $0.value >= needed }
                .sorted { $0.value == $1.value ? $0.key.count > $1.key.count : $0.value > $1.value }
                .map(\.key)
            if dropsParts {
                picked = picked.filter { phrase in
                    !picked.contains { $0 != phrase && $0.contains(phrase) && (counts[$0] ?? 0) * 10 >= (counts[phrase] ?? 0) * 7 }
                }
            }
            return Array(picked.prefix(limit))
        }

        mutating func add(_ sample: Sample, date: Date, detailed: Bool) {
            messages += 1
            if let greeting = sample.greeting { greetings[greeting, default: 0] += 1 }
            if let signOff = sample.signOff { signOffs[signOff, default: 0] += 1 }
            Self.keep(sample.words, in: &lengths)
            if let sentence = sample.sentenceLength { Self.keep(sentence, in: &sentenceLengths) }
            Self.keep(sample.paragraphs, in: &paragraphCounts)
            if sample.contractions { contractions += 1 }
            if sample.exclamation { exclamations += 1 }
            if sample.emoji { emoji += 1 }
            if sample.dash { dashes += 1 }
            if sample.formal == true { formal += 1 }
            if sample.formal == false { informal += 1 }
            if sample.lowercase { lowercase += 1 }
            if let opener = sample.opener { openers[opener, default: 0] += 1 }
            if let closer = sample.closer { closers[closer, default: 0] += 1 }
            if let name = sample.signedName { signedNames[name, default: 0] += 1 }
            if detailed {
                for phrase in sample.phrases { phrases[phrase, default: 0] += 1 }
                // Phrases used once fall away once there are many, so the profile stays small.
                if phrases.count > 4_000 { phrases = phrases.filter { $0.value > 1 } }
            }
            if openers.count > 400 { openers = openers.filter { $0.value > 1 } }
            if closers.count > 400 { closers = closers.filter { $0.value > 1 } }
            lastWritten = max(lastWritten ?? date, date)
        }

        private static func keep(_ value: Int, in list: inout [Int]) {
            list.append(value)
            if list.count > 50 { list.removeFirst(list.count - 50) }
        }

        // Profiles saved before a field existed still load.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            greetings = try c.decodeIfPresent([String: Int].self, forKey: .greetings) ?? [:]
            signOffs = try c.decodeIfPresent([String: Int].self, forKey: .signOffs) ?? [:]
            lengths = try c.decodeIfPresent([Int].self, forKey: .lengths) ?? []
            messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
            contractions = try c.decodeIfPresent(Int.self, forKey: .contractions) ?? 0
            exclamations = try c.decodeIfPresent(Int.self, forKey: .exclamations) ?? 0
            emoji = try c.decodeIfPresent(Int.self, forKey: .emoji) ?? 0
            dashes = try c.decodeIfPresent(Int.self, forKey: .dashes) ?? 0
            lastWritten = try c.decodeIfPresent(Date.self, forKey: .lastWritten)
            sentenceLengths = try c.decodeIfPresent([Int].self, forKey: .sentenceLengths) ?? []
            paragraphCounts = try c.decodeIfPresent([Int].self, forKey: .paragraphCounts) ?? []
            formal = try c.decodeIfPresent(Int.self, forKey: .formal) ?? 0
            informal = try c.decodeIfPresent(Int.self, forKey: .informal) ?? 0
            lowercase = try c.decodeIfPresent(Int.self, forKey: .lowercase) ?? 0
            phrases = try c.decodeIfPresent([String: Int].self, forKey: .phrases) ?? [:]
            openers = try c.decodeIfPresent([String: Int].self, forKey: .openers) ?? [:]
            closers = try c.decodeIfPresent([String: Int].self, forKey: .closers) ?? [:]
            signedNames = try c.decodeIfPresent([String: Int].self, forKey: .signedNames) ?? [:]
        }
    }

    /// How someone writes, in a model's words: written once from a sample of their sent mail,
    /// with what it was written by, so drafts can follow more than what counting finds.
    public struct Voice: Codable, Hashable, Sendable {
        public var text: String
        /// "Claude Code · Sonnet".
        public var by: String
        public var emails: Int
        public var date: Date

        public init(text: String, by: String, emails: Int, date: Date = Date()) {
            self.text = text
            self.by = by
            self.emails = emails
            self.date = date
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
    /// People forgotten on purpose: not learned about again.
    public var forgotten: Set<String> = []
    /// Studied voices by language code ("nl"; "" when the language isn't known).
    public var voices: [String: Voice] = [:]
    /// What this profile's learning knows how to read. Older ones are learned again from sent
    /// mail, so they gain what's been added since (sentence length, phrases, address).
    public var version = 0
    public static let currentVersion = 3

    public init() { version = Self.currentVersion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overall = try c.decodeIfPresent(Habits.self, forKey: .overall) ?? Habits()
        languages = try c.decodeIfPresent([String: Habits].self, forKey: .languages) ?? [:]
        people = try c.decodeIfPresent([String: Habits].self, forKey: .people) ?? [:]
        peopleByLanguage = try c.decodeIfPresent([String: Habits].self, forKey: .peopleByLanguage) ?? [:]
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        learned = try c.decodeIfPresent(Set<String>.self, forKey: .learned) ?? []
        forgotten = try c.decodeIfPresent(Set<String>.self, forKey: .forgotten) ?? []
        voices = try c.decodeIfPresent([String: Voice].self, forKey: .voices) ?? [:]
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    /// The same profile with everything counted taken out, to learn again: who was forgotten
    /// and the studied voices stay.
    public var startedAgain: WritingProfile {
        var fresh = WritingProfile()
        fresh.forgotten = forgotten
        fresh.voices = voices
        return fresh
    }

    /// The studied voice for a language, else the one studied without a language, else any.
    public func voice(for language: String?) -> Voice? {
        if let language, let voice = voices[language] { return voice }
        return voices[""] ?? (language == nil ? voices.values.max { $0.emails < $1.emails } : nil)
    }

    public var isEmpty: Bool { overall.messages == 0 }

    /// Learns from one sent message. Quoted text and the signature are left out. Returns false
    /// when the message was already learned from or had nothing of the person's own writing.
    @discardableResult
    public mutating func learn(_ text: String, to recipients: [EmailAddress], signature: String? = nil,
                               id: String? = nil, date: Date = Date()) -> Bool {
        if let id, learned.contains(id) { return false }
        let own = Self.ownWriting(text, signature: signature)
        guard !own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let language = Self.language(of: own)
        let sample = Sample(own, recipient: recipients.first, language: language)
        overall.add(sample, date: date, detailed: true)
        if let language { languages[language, default: Habits()].add(sample, date: date, detailed: true) }
        // Per person only for one-to-one mail: a group message says less about one reader.
        if recipients.count == 1, let person = recipients.first, !forgotten.contains(person.address.lowercased()) {
            let key = person.address.lowercased()
            people[key, default: Habits()].add(sample, date: date, detailed: false)
            if let language { peopleByLanguage["\(language)|\(key)", default: Habits()].add(sample, date: date, detailed: false) }
            names[key] = person.displayName
        }
        if let id { learned.insert(id) }
        return true
    }

    public mutating func forget(_ address: String) {
        forgotten.insert(address.lowercased())
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
    /// `theirs` is how the other person addresses you in the conversation (true formally, false
    /// informally), from `formality(_:language:)` on their latest message.
    public func styleGuide(for recipient: EmailAddress?, myName: String, language: String? = nil, theirs: Bool? = nil) -> String? {
        guard overall.messages >= 3 else { return nil }
        // The name they sign with ("Kaan"), not a mailbox's display name.
        let myName = overall.usualSignedName ?? myName
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
        // A ceiling, never a target: a model told "about 200 words" pads a two-line answer.
        if let length = tone.typicalLength {
            lines.append("As long as the reply needs and no longer: \(myName)'s emails are usually under \(max(length, 30)) words, and a short message gets a short answer.")
        }
        if let sentence = tone.typicalSentence {
            lines.append(sentence <= 12 ? "Sentences are short and plain." : sentence <= 20 ? "Sentences are of medium length." : "Longer sentences are fine.")
        }
        if let lang, let forms = Self.addressForms[lang] {
            lines.append(Self.addressLine(forms, reader: first.isEmpty ? "the reader" : first,
                                          mine: key.flatMap { addressUsed(with: $0, language: lang) }, theirs: theirs))
        }
        if tone.writesLowercase { lines.append("Write in lower case, as \(myName) does.") }
        // Contractions are how casual English reads; other languages show it differently.
        if lang == nil || lang == "en" || languages.isEmpty {
            lines.append(tone.isCasual ? "Sound casual: use contractions like I'm and don't." : "Sound polished: avoid slang.")
        }
        // Never using them is only clear from enough mail, everyone's in the language.
        let broad = known ?? overall
        if tone.usesExclamations { lines.append("An exclamation mark now and then is fine.") } else if broad.messages >= 5 && !broad.usesExclamations {
            lines.append("Don't use exclamation marks.")
        }
        if tone.usesEmoji { lines.append("An emoji is fine if it fits.") }
        if !tone.usesDashes { lines.append("Never use an em dash (—) or en dash (–). Use a comma or a full stop instead.") }
        // Wording carries over within a language only; per person there's too little, so the
        // language's (or everyone's) habits. A study already says this better.
        let voice = voice(for: lang)
        let words = voice != nil ? nil : known ?? (lang == nil || languages.isEmpty ? overall : nil)
        if let words {
            let openers = words.habitualOpeners
            if !openers.isEmpty { lines.append("\(myName) often starts the first sentence like: " + Self.quoted(openers.map { $0 + " …" }) + ".") }
            let closers = words.habitualClosers
            if !closers.isEmpty { lines.append("\(myName) often ends with: " + Self.quoted(closers) + ".") }
            let phrases = words.habitualPhrases
            if !phrases.isEmpty { lines.append("Phrases \(myName) often uses, only where they fit: " + Self.quoted(phrases) + ".") }
        }
        lines.append("Don't add pleasantries \(myName) doesn't use, like hoping the email finds them well.")
        lines.append("Say each thing once: no repeated thanks or enthusiasm, no filler sentences.")
        let who = personal != nil ? " to \(recipient?.displayName ?? "")" : ""
        // Rules only, no sample emails: small models copy a sample's content into unrelated replies.
        let rules = "Write the way \(myName) writes\(who):\n- " + lines.joined(separator: "\n- ")
        // The study comes first: it heard how they sound, which counting can't.
        guard let voice else { return rules }
        return "How \(myName) writes, studied from their sent mail (style only; never reuse its examples as content):\n"
            + voice.text + "\n\n" + rules
            + "\n\nWhere these rules and the description above differ, follow the description."
    }

    /// How to say "you" to this reader. Per person, never from habits with others: what you've
    /// used with them before; else what they use with you; else the formal form, as is usual
    /// with someone you haven't written to.
    static func addressLine(_ forms: (informal: String, formal: String), reader: String, mine: Bool?, theirs: Bool?) -> String {
        if let mine {
            return mine ? "You address \(reader) formally (\(forms.formal)); keep doing so, never \(forms.informal)."
                        : "You address \(reader) informally (\(forms.informal)); keep doing so, never \(forms.formal)."
        }
        if let theirs {
            return theirs ? "\(reader) addresses you formally, so reply formally (\(forms.formal)), not \(forms.informal)."
                          : "\(reader) addresses you informally, so reply informally (\(forms.informal)) too."
        }
        return "Address \(reader) formally (\(forms.formal)), as is usual with someone you haven't written to before; only use \(forms.informal) once they do."
    }

    /// Formal (true) or informal (false) address in what you've sent this person, in the language
    /// when known; nil when it never showed or was evenly split.
    func addressUsed(with key: String, language: String?) -> Bool? {
        let habits = language.flatMap { peopleByLanguage["\($0)|\(key)"] } ?? people[key]
        guard let habits else { return nil }
        if habits.formal > habits.informal { return true }
        if habits.informal > habits.formal { return false }
        return nil
    }

    /// The informal and formal ways to say "you", where a language makes the choice.
    static let addressForms: [String: (informal: String, formal: String)] = [
        "nl": ("je/jij", "u"), "de": ("du", "Sie"), "fr": ("tu", "vous"), "es": ("tú", "usted"),
    ]

    static func quoted(_ items: [String]) -> String {
        items.map { "\"\($0)\"" }.joined(separator: ", ")
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
        /// The middle sentence length, in words.
        var sentenceLength: Int?
        var paragraphs: Int
        /// True formal, false informal, nil when it doesn't say.
        var formal: Bool?
        var lowercase: Bool
        var opener: String?
        var closer: String?
        var signedName: String?
        /// Three- and four-word phrases in it, each once.
        var phrases: Set<String>

        init(_ text: String, recipient: EmailAddress?, language: String? = nil) {
            let allLines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            let lines = allLines.filter { !$0.isEmpty }
            greeting = lines.first.flatMap { WritingProfile.greeting(in: $0, recipient: recipient) }
            signOff = WritingProfile.signOff(in: lines)
            signedName = WritingProfile.signedName(in: lines, after: signOff)
            words = text.split { $0.isWhitespace || $0.isNewline }.count
            contractions = text.range(of: #"\b\w+'(m|re|s|ve|ll|d|t)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                || text.contains("’")
            exclamation = text.contains("!")
            emoji = text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            dash = text.contains("—") || text.contains(" – ")

            // The body: without the greeting line, and without the sign-off and what follows it.
            var body = allLines
            if greeting != nil, let first = body.firstIndex(where: { !$0.isEmpty }) { body.remove(at: first) }
            if let signOff, let index = body.lastIndex(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) == signOff }) {
                body = Array(body[..<index])
            }
            let bodyText = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphs = max(1, bodyText.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
            let sentences = WritingProfile.sentences(in: bodyText)
            // Real sentences only: a line like "Thanks!" or a list item isn't one.
            let counts = sentences.filter { $0.last.map { ".!?".contains($0) } ?? false }
                .map { $0.split(whereSeparator: \.isWhitespace).count }.filter { $0 >= 3 }
            sentenceLength = counts.isEmpty ? nil : counts.sorted()[counts.count / 2]
            let starts = sentences.compactMap { $0.first(where: \.isLetter) }
            lowercase = starts.count >= 2 && starts.filter(\.isLowercase).count * 10 >= starts.count * 8
            formal = WritingProfile.formality(bodyText, language: language)
            opener = sentences.first.flatMap { WritingProfile.opening(of: $0) }
            closer = sentences.count >= 2 ? sentences.last.flatMap { WritingProfile.closing($0) } : nil
            phrases = WritingProfile.phrases(in: sentences)
        }
    }

    /// The name on the line under the sign-off: one or two words, letters only.
    static func signedName(in lines: [String], after signOff: String?) -> String? {
        guard let signOff, let index = lines.lastIndex(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) == signOff }),
              index + 1 < lines.count else { return nil }
        let name = lines[index + 1].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        let parts = name.split(separator: " ")
        guard (1...2).contains(parts.count), name.count <= 30, name.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }),
              name.first?.isUppercase == true else { return nil }
        return String(parts[0])
    }

    /// The sentences of a text: a sentence ends at . ! ? or a line break.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = line
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let sentence = line[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                return true
            }
        }
        return result
    }

    /// Words of a sentence, lower case, with punctuation taken off the ends; nil for a word
    /// that's a name (a capital inside the sentence) or has digits, which say nothing about style.
    static func styleWords(_ sentence: String) -> [String?] {
        sentence.split(whereSeparator: \.isWhitespace).enumerated().map { index, raw in
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !word.isEmpty, !word.contains(where: \.isNumber), !word.contains("@") else { return nil }
            if index > 0, word.first?.isUppercase == true, word.lowercased() != "i" { return nil }
            return word.lowercased()
        }
    }

    static func phrases(in sentences: [String]) -> Set<String> {
        var found: Set<String> = []
        for sentence in sentences {
            let words = styleWords(sentence)
            for size in 3...4 where words.count >= size {
                for start in 0...(words.count - size) {
                    let run = words[start..<(start + size)]
                    guard run.allSatisfy({ $0 != nil }) else { continue }
                    found.insert(run.compactMap { $0 }.joined(separator: " "))
                }
            }
        }
        return found
    }

    /// The first three words of the first sentence ("thanks for the"), when none is a name.
    static func opening(of sentence: String) -> String? {
        let words = styleWords(sentence)
        guard words.count >= 4, words.prefix(3).allSatisfy({ $0 != nil }) else { return nil }
        let raw = sentence.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
    }

    /// A closing sentence short enough to be a habit, without names or numbers.
    static func closing(_ sentence: String) -> String? {
        let words = styleWords(sentence)
        guard (2...10).contains(words.count), words.allSatisfy({ $0 != nil }) else { return nil }
        return sentence
    }

    /// Formal or informal address, in languages that make the choice. German's formal Sie is
    /// told from sie (she, they) by its capital inside a sentence.
    public static func formality(_ text: String, language: String?) -> Bool? {
        let lists: (informal: Set<String>, formal: Set<String>)
        switch language {
        case "nl": lists = (["je", "jij", "jou", "jouw", "jullie"], ["u", "uw"])
        case "fr": lists = (["tu", "te", "toi", "ton", "ta", "tes", "t'"], ["vous", "votre", "vos"])
        case "es": lists = (["tú", "te", "ti", "contigo"], ["usted", "ustedes"])
        case "de": lists = (["du", "dich", "dir", "dein", "deine", "deinen", "deinem", "deiner"], ["Sie", "Ihnen", "Ihr", "Ihre", "Ihren", "Ihrem", "Ihrer"])
        default: return nil
        }
        var informal = 0, formal = 0
        for sentence in sentences(in: text) {
            for (index, raw) in sentence.split(whereSeparator: \.isWhitespace).enumerated() {
                let word = raw.trimmingCharacters(in: .punctuationCharacters)
                if language == "de" {
                    if index > 0, lists.formal.contains(word) { formal += 1 }
                    if lists.informal.contains(word.lowercased()) { informal += 1 }
                } else {
                    let lower = word.lowercased()
                    if lists.formal.contains(lower) { formal += 1 }
                    if lists.informal.contains(lower) { informal += 1 }
                }
            }
        }
        if formal == 0 && informal == 0 { return nil }
        return formal > informal
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
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("---------- Forwarded") || trimmed == "-- " || trimmed == "--" { break }
            // "On Tue, Noor wrote:", also when the mail app wrapped it onto two lines.
            if quoteIntro.contains(where: { lower.hasSuffix($0) }) {
                if let last = kept.last?.trimmingCharacters(in: .whitespaces), quoteIntroStart.contains(where: { last.hasPrefix($0) }),
                   !quoteIntroStart.contains(where: { trimmed.hasPrefix($0) }) {
                    kept.removeLast()
                }
                break
            }
            // Outlook's quote: "From: …" with "Sent:" or "Date:" under it (and the same in Dutch,
            // German and French), or its line of underscores.
            if quoteHeader.contains(where: { lower.hasPrefix($0) }),
               lines.dropFirst(index + 1).prefix(3).contains(where: { next in quoteHeaderNext.contains { next.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix($0) } }) { break }
            if trimmed.count >= 10, trimmed.allSatisfy({ $0 == "_" }) { break }
            if lower.hasPrefix("-----original message") || lower.hasPrefix("-----oorspronkelijk bericht") || lower.hasPrefix("-----ursprüngliche nachricht") { break }
            // "Sent from Outlook for iOS", "Verstuurd vanaf mijn iPhone": the phone's, not theirs.
            if phoneSignatures.contains(where: { lower.hasPrefix($0) }) { break }
            kept.append(line)
        }
        var own = kept.joined(separator: "\n")
        if let signature = signature?.trimmingCharacters(in: .whitespacesAndNewlines), !signature.isEmpty {
            own = own.replacingOccurrences(of: signature, with: "")
        }
        return own.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension WritingProfile {
    static let quoteIntro = ["wrote:", "schreef:", "schrieb:", "a écrit :", "a écrit:", "escribió:", "ha scritto:"]
    static let quoteIntroStart = ["On ", "Op ", "Am ", "Le ", "El ", "Il "]
    static let quoteHeader = ["from:", "van:", "von:", "de :", "de:", "da:"]
    static let quoteHeaderNext = ["sent:", "date:", "verzonden:", "datum:", "gesendet:", "envoyé :", "envoyé:", "to:", "aan:", "an:"]
    static let phoneSignatures = ["sent from margin", "sent from my", "sent from outlook", "get outlook for", "verzonden vanaf", "verstuurd vanaf",
                                  "verzonden met", "von meinem iphone", "envoyé de mon"]
}

extension EmailAddress {
    /// "Noor Haddad" → "Noor"; an address without a name gives its local part.
    public static func firstName(of address: EmailAddress) -> String {
        address.displayName.split(separator: " ").first.map(String.init) ?? address.displayName
    }
}
