import Foundation

/// A reaction to a message: 👍 ❤️ 🎉 😆 😮 😢.
///
/// Mail has no reactions of its own. Outlook keeps them inside Microsoft's servers (no public
/// API reads or adds them), and when someone there reacts to mail from outside, it sends a short
/// email instead: "RE: <subject>", then "[laugh] Jane Jolie reacted to your message:" and the
/// original quoted. Margin reads those emails, and replies that are nothing but an emoji, as
/// reactions on the message they answer, and sends its own reactions in Outlook's shape.
public struct MailReaction: Hashable, Sendable {
    /// The six reactions Outlook offers, in its order.
    public enum Kind: String, CaseIterable, Sendable {
        case like, heart, celebrate, laugh, surprised, sad

        public var emoji: String {
            switch self {
            case .like: "👍"
            case .heart: "❤️"
            case .celebrate: "🎉"
            case .laugh: "😆"
            // Outlook's "surprised" is the astonished face.
            case .surprised: "😲"
            case .sad: "😢"
            }
        }
    }

    /// What was reacted with; nil when the email didn't say (a token in a language Margin
    /// doesn't know).
    public var emoji: String?
    public var from: EmailAddress
    public var date: Date
    /// The reaction email itself (`MailMessage.id`).
    public var messageID: String
    /// The Message-ID of the message reacted to, when the email names it.
    public var inReplyTo: String?
    /// Outlook's notice that someone took their reaction back.
    public var isRemoval: Bool

    public init(emoji: String?, from: EmailAddress, date: Date, messageID: String, inReplyTo: String? = nil, isRemoval: Bool = false) {
        self.emoji = emoji
        self.from = from
        self.date = date
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.isRemoval = isRemoval
    }

    /// Outlook's word for a reaction taken back (its picture is described as "0").
    static let removed = "0"

    // MARK: Gmail's format

    /// Gmail's documented reaction part, sent between the text and the HTML:
    /// https://developers.google.com/workspace/gmail/reactions/format
    public static let gmailType = "text/vnd.google.email-reaction+json"

    /// `{"version":1,"emoji":"👍"}`
    public static func gmailJSON(_ emoji: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["version": 1, "emoji": emoji], options: [.sortedKeys])) ?? Data()
    }

    /// The emoji of a Gmail reaction part; nil when it isn't valid (version 1, one emoji).
    public static func gmailEmoji(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, version == 1,
              let emoji = (object["emoji"] as? String)?.trimmingCharacters(in: .whitespaces),
              emoji.count == 1, let character = emoji.first, isEmoji(character) else { return nil }
        return emoji
    }

    // MARK: Recognising

    /// Outlook's names for its six reactions, as they appear in brackets ("[like]") or in its
    /// reaction picture's address (`…/assets/reaction/like.png`). Microsoft's identifiers, not words.
    static let tokens: [String: String] = [
        "like": "👍", "heart": "❤️", "celebrate": "🎉", "laugh": "😆", "surprised": "😲", "sad": "😢",
    ]

    /// Recognises a reaction email: Outlook's ("[like] Jane reacted to your message:") or a reply
    /// that is only an emoji. `text` is the plain text (the preview will do), `html` the
    /// formatted version when there is one.
    /// `gmail` is the emoji of a Gmail reaction part, when the message has one. Only replies are
    /// looked at (Outlook's are "RE: …"), which keeps sorting a big inbox quick.
    public static func detect(_ message: MailMessage, text: String, html: String? = nil, gmail: String? = nil) -> MailReaction? {
        if let gmail, message.inReplyTo != nil {
            return MailReaction(emoji: gmail, from: message.from, date: message.date, messageID: message.id, inReplyTo: message.inReplyTo)
        }
        guard startsLikeOne(text, sender: message.from), message.inReplyTo != nil || !message.references.isEmpty else { return nil }
        if let emoji = outlookStyle(text: text, html: html, sender: message.from, isReply: true) {
            let isRemoval = emoji == removed
            return MailReaction(emoji: emoji.isEmpty || isRemoval ? nil : emoji, from: message.from, date: message.date,
                                messageID: message.id, inReplyTo: message.inReplyTo, isRemoval: isRemoval)
        }
        if let emoji = emojiOnly(text) {
            return MailReaction(emoji: emoji, from: message.from, date: message.date, messageID: message.id, inReplyTo: message.inReplyTo)
        }
        return nil
    }

    /// Every reaction starts with "[", an emoji, or the sender's name ("Jane Jolie reacted…"),
    /// which rules out almost all mail before any real work.
    static func startsLikeOne(_ text: String, sender: EmailAddress) -> Bool {
        let start = text.drop(while: \.isWhitespace)
        guard let first = start.first else { return false }
        // "<https://…/assets/reaction/like.png>" is how some apps write Outlook's picture as text.
        if first == "[" || first == "<" || isEmoji(first) { return true }
        guard let name = sender.name, name.count >= 2 else { return start.count <= 160 }
        return start.prefix(name.count).caseInsensitiveCompare(name) == .orderedSame
    }

    /// The reaction in an Outlook-style first line, "" when it's a reaction of an unknown kind,
    /// nil when it isn't one.
    static func outlookStyle(text: String, html: String?, sender: EmailAddress, isReply: Bool) -> String? {
        let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard !firstLine.isEmpty else { return nil }

        // The reaction in front: "[like]", Outlook's picture as a link, or an emoji.
        var emoji: String?
        var rest = Substring(firstLine)
        if let match = firstLine.firstMatch(of: bracketed) {
            emoji = token(String(match.1))
            rest = firstLine[match.range.upperBound...]
        } else if let match = firstLine.firstMatch(of: pictureLink) {
            emoji = token(String(match.1))
            rest = firstLine[match.range.upperBound...]
        } else {
            let lead = rest.prefix(while: isEmoji)
            if !lead.isEmpty, lead.count <= 3 {
                emoji = String(lead)
                rest = rest.dropFirst(lead.count)
            }
        }
        // A preview runs everything together; the line ends at its colon.
        let window = rest.prefix(300)
        let colon = window.firstIndex { $0 == ":" || $0 == "：" }
        rest = colon.map { rest[..<$0] } ?? window
        let remainder = rest.trimmingCharacters(in: .whitespaces)
        let lower = remainder.lowercased()
        // "Jolie, Jane" in the header is "Jane Jolie" in the text.
        let header = sender.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let parts = header.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let names = parts.count == 2 ? [header, parts[1] + " " + parts[0]] : [header]
        let name = names.first { $0.count >= 2 && lower.hasPrefix($0.lowercased()) } ?? header
        let startsWithName = name.count >= 2 && lower.hasPrefix(name.lowercased())
        if emoji == nil, let picture = pictureToken(in: html) { emoji = picture }
        // Outlook's shape, in any language: a known reaction, then the sender's name and a few
        // words before the colon, in a reply ("[like] Jane Jolie reacted to your message:").
        // Its words aren't read.
        // A tag Margin can't read ("[EXTERNAL]") or a name alone ("👍 Jane: sure") isn't enough.
        guard let emoji, isReply, !emoji.isEmpty, colon != nil, startsWithName,
              remainder.count > name.count + 3, remainder.count <= name.count + 60 else { return nil }
        return emoji
    }

    /// The emoji for a reaction's name ("like"), `removed` for a reaction taken back, "" for a
    /// name Margin doesn't know.
    static func token(_ name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if key == removed { return removed }
        return tokens[key] ?? ""
    }

    /// The reaction Outlook's formatted version shows as a picture
    /// (`<img alt="like" src="https://…/assets/reaction/like.png">`), from its address or its
    /// description.
    static func pictureToken(in html: String?) -> String? {
        guard let html else { return nil }
        let start = html.prefix(8000)
        if let match = start.firstMatch(of: pictureFile) {
            let found = token(String(match.1))
            if !found.isEmpty { return found }
        }
        for match in start.matches(of: /<img[^>]*?\salt\s*=\s*["']([^"']{1,32})["']/.ignoresCase()) {
            let alt = String(match.1).trimmingCharacters(in: .whitespaces)
            let found = token(alt)
            if !found.isEmpty { return found }
            if !alt.isEmpty, alt.allSatisfy(isEmoji) { return alt }
        }
        return nil
    }

    nonisolated(unsafe) private static let pictureLink = /^<[^>\s]*\/assets\/reaction\/([A-Za-z0-9_]+)\.png[^>]*>/
    nonisolated(unsafe) private static let pictureFile = /\/assets\/reaction\/([A-Za-z0-9_]+)\.png/

    /// The emoji when a reply is nothing else: "👍", maybe a signature line or the quoted
    /// original after it.
    static func emojiOnly(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = trimmed.prefix(while: isEmoji)
        guard !lead.isEmpty, lead.count <= 3 else { return nil }
        let after = trimmed.dropFirst(lead.count).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Nothing after it but the quoted original or a separator line.
        if after.isEmpty || after.hasPrefix(">") || after.hasPrefix("____") || after.hasPrefix("-----") { return String(lead) }
        return nil
    }

    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation || first == "\u{2764}" { return true }
        // "❤️" is a plain heart turned into a picture; digits and "#" are "emoji" only with a keycap.
        return first.properties.isEmoji && scalars.count > 1 && !("0"..."9").contains(first) && first != "#" && first != "*"
    }

    static func isReplySubject(_ subject: String) -> Bool {
        // A prefix ends in a colon within its first few letters; most subjects stop here.
        guard subject.prefix(10).contains(where: { $0 == ":" || $0 == "：" }) else { return false }
        return subject.firstMatch(of: replyPrefix) != nil
    }

    nonisolated(unsafe) private static let bracketed = /^\[([^\]]{1,24})\]/
    nonisolated(unsafe) private static let replyPrefix = /^\s*(re|aw|sv|antw|res|r|rif|vs|odp|ynt|απ|回复|答复|回覆)\s*(\[\d+\])?\s*[:：]/.ignoresCase()

    /// The subject without "RE:" and its kin, as written.
    public static func originalSubject(_ subject: String) -> String {
        var text = subject
        while let match = text.firstMatch(of: replyPrefix) { text = String(text[match.range.upperBound...]) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Placing reactions on the messages they answer

    /// A conversation's messages to show, with the reactions taken out and put on the messages
    /// they answer (by `MailMessage.id`).
    public struct Layout: Sendable {
        public var messages: [MailMessage]
        public var reactions: [String: [MailReaction]]
    }

    /// Takes reactions out of a conversation and puts them on the message they answer: the one
    /// their reply headers name, or else the latest earlier message someone else wrote. A
    /// reaction whose message isn't in the conversation stays, to be shown as a small card.
    public static func layout(_ messages: [MailMessage], reaction: (MailMessage) -> MailReaction?) -> Layout {
        var found: [String: MailReaction] = [:]
        for message in messages { if let r = reaction(message) { found[message.id] = r } }
        guard !found.isEmpty else { return Layout(messages: messages, reactions: [:]) }
        var hidden = Set<String>()
        var placed: [String: [MailReaction]] = [:]
        for message in messages {
            guard let r = found[message.id] else { continue }
            let candidates = messages.filter { found[$0.id] == nil }
            let named = r.inReplyTo.flatMap { id in candidates.first { $0.messageID == id } }
            let target = named ?? candidates.last {
                $0.date <= r.date && $0.from.address.lowercased() != r.from.address.lowercased()
            }
            guard let target else { continue }
            hidden.insert(message.id)
            // One reaction per person on a message: their latest. Taking it back leaves none.
            var list = placed[target.id] ?? []
            list.removeAll { $0.from.address.lowercased() == r.from.address.lowercased() && $0.date <= r.date }
            if !r.isRemoval, !list.contains(where: { $0.from.address.lowercased() == r.from.address.lowercased() }) { list.append(r) }
            placed[target.id] = list.isEmpty ? nil : list.sorted { $0.date < $1.date }
        }
        let shown = messages.filter { !hidden.contains($0.id) }
        guard !shown.isEmpty else { return Layout(messages: messages, reactions: [:]) }
        return Layout(messages: shown, reactions: placed)
    }

    /// A conversation as a list row tells it: reactions left out (read from the previews) when
    /// there's anything else, since the reader shows them on their message. Only for showing.
    public static func withoutReactions(_ thread: MailThread) -> MailThread {
        let kept = thread.messages.filter { detect($0, text: $0.snippet) == nil }
        guard !kept.isEmpty, kept.count < thread.messages.count else { return thread }
        return MailThread(id: thread.id, messages: kept, accountID: thread.accountID)
    }

    /// Reactions grouped by emoji, in the order each first appeared; "" groups the unknown kind.
    public static func grouped(_ reactions: [MailReaction]) -> [(emoji: String, people: [EmailAddress])] {
        var order: [String] = []
        var people: [String: [EmailAddress]] = [:]
        for r in reactions {
            let key = r.emoji ?? ""
            if people[key] == nil { order.append(key) }
            people[key, default: []].append(r.from)
        }
        return order.map { ($0, people[$0] ?? []) }
    }

    // MARK: Reacting

    /// Whether a message can be reacted to: written by a person (not a list or a system), not by
    /// you, with a Message-ID to answer, and not marked by its sender as not wanting reactions
    /// (`x-ms-reactions: disallow`, which Outlook honours too).
    public static func canReact(to message: MailMessage, me: Set<String>) -> Bool {
        guard message.messageID != nil, !me.contains(message.from.address.lowercased()) else { return false }
        if message.listHeaders["x-ms-reactions"]?.trimmingCharacters(in: .whitespaces).lowercased() == "disallow" { return false }
        return InboxSplit.classify(message) == .people
    }

    /// A reaction as a short reply in Outlook's shape, so it reads the same to someone on
    /// Outlook, in Margin, or in any other app: the reaction and who reacted, then the original.
    /// It also carries Gmail's reaction part, so Gmail shows it as a reaction.
    /// Written in `language` (an app language code such as "de" or "pt-BR").
    public static func reply(_ emoji: String, to message: MailMessage, originalText: String, from me: EmailAddress,
                             language: String, timeZone: TimeZone = .current) -> Draft {
        let words = Wording.for(language)
        let name = me.name.flatMap { $0.isEmpty ? nil : $0 } ?? me.address
        let date = DateFormatter()
        date.locale = Locale(identifier: language)
        date.timeZone = timeZone
        date.dateStyle = .full
        date.timeStyle = .short
        let recipients = (message.to + message.cc).map(\.headerValue).joined(separator: "; ")
        let text = """
        \(emoji) \(words.sentence.replacingOccurrences(of: "{name}", with: name))
        ________________________________
        \(words.from): \(message.from.headerValue)
        \(words.sent): \(date.string(from: message.date))
        \(words.to): \(recipients)
        \(words.subject): \(message.subject)

        \(originalText.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        let subject = isReplySubject(message.subject) ? message.subject : "RE: \(message.subject)"
        let references = message.references + [message.messageID].compactMap { $0 }
        var draft = Draft(from: me, to: [message.from], subject: subject, text: text, inReplyTo: message.messageID, references: references)
        // Gmail shows it as a reaction when its rules are met: you were in To or Cc, among at
        // most 20 people.
        let people = Set((message.to + message.cc).map { $0.address.lowercased() })
        if people.contains(me.address.lowercased()), people.count <= 20 { draft.reaction = emoji }
        return draft
    }

    /// The words of a reaction email Margin sends, in the reader's language. Coming back, only
    /// its shape is read (the reaction, then the name), never these words.
    struct Wording {
        var sentence: String
        var from: String
        var sent: String
        var to: String
        var subject: String

        static func `for`(_ language: String) -> Wording {
            let code = language.lowercased()
            // Traditional Chinese (Taiwan, Hong Kong) has its own words.
            if code.hasPrefix("zh-hant") || code == "zh-tw" || code == "zh-hk" { return table["zh-hant"]! }
            let base = code.split(separator: "-").first.map(String.init) ?? code
            return table[base] ?? table["en"]!
        }

        static let table: [String: Wording] = [
            "en": Wording(sentence: "{name} reacted to your message:", from: "From", sent: "Sent", to: "To", subject: "Subject"),
            "de": Wording(sentence: "{name} hat auf Ihre Nachricht reagiert:", from: "Von", sent: "Gesendet", to: "An", subject: "Betreff"),
            "es": Wording(sentence: "{name} reaccionó a tu mensaje:", from: "De", sent: "Enviado", to: "Para", subject: "Asunto"),
            "fr": Wording(sentence: "{name} a réagi à votre message :", from: "De", sent: "Envoyé", to: "À", subject: "Objet"),
            "hi": Wording(sentence: "{name} ने आपके संदेश पर प्रतिक्रिया दी:", from: "प्रेषक", sent: "भेजा गया", to: "प्रति", subject: "विषय"),
            "hu": Wording(sentence: "{name} reagált az üzenetére:", from: "Feladó", sent: "Elküldve", to: "Címzett", subject: "Tárgy"),
            "it": Wording(sentence: "{name} ha reagito al tuo messaggio:", from: "Da", sent: "Inviato", to: "A", subject: "Oggetto"),
            "ja": Wording(sentence: "{name} さんがあなたのメッセージにリアクションしました:", from: "差出人", sent: "送信日時", to: "宛先", subject: "件名"),
            "ko": Wording(sentence: "{name}님이 메시지에 반응했습니다:", from: "보낸 사람", sent: "보낸 날짜", to: "받는 사람", subject: "제목"),
            "nl": Wording(sentence: "{name} heeft gereageerd op je bericht:", from: "Van", sent: "Verzonden", to: "Aan", subject: "Onderwerp"),
            "pt": Wording(sentence: "{name} reagiu à sua mensagem:", from: "De", sent: "Enviado", to: "Para", subject: "Assunto"),
            "ru": Wording(sentence: "{name} отреагировал(а) на ваше сообщение:", from: "От", sent: "Отправлено", to: "Кому", subject: "Тема"),
            "zh": Wording(sentence: "{name} 回应了你的邮件：", from: "发件人", sent: "发送时间", to: "收件人", subject: "主题"),
            "zh-hant": Wording(sentence: "{name} 回應了你的郵件：", from: "寄件者", sent: "寄件日期", to: "收件者", subject: "主旨"),
            "tr": Wording(sentence: "{name} iletinize tepki verdi:", from: "Kimden", sent: "Gönderildi", to: "Kime", subject: "Konu"),
            // Gender-neutral, with the name first as in every language: "{name}: a reaction".
            "pl": Wording(sentence: "{name} – reakcja na Twoją wiadomość:", from: "Od", sent: "Wysłano", to: "Do", subject: "Temat"),
            "sv": Wording(sentence: "{name} reagerade på ditt meddelande:", from: "Från", sent: "Skickat", to: "Till", subject: "Ämne"),
        ]
    }
}
