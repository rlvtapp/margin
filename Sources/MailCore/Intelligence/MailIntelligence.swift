import Foundation

/// A short read of a conversation.
public struct ThreadSummary: Codable, Hashable, Sendable {
    /// One sentence: what this conversation is about and where it stands.
    public var headline: String
    /// Up to four facts worth knowing.
    public var points: [String]
    /// What the reader is asked to do, if anything.
    public var action: String?

    public init(headline: String, points: [String], action: String?) {
        self.headline = headline
        self.points = points
        self.action = action
    }
}

/// How to write or rewrite a reply.
public enum WriteInstruction: Hashable, Sendable {
    /// A first draft. The optional note says what to say ("say yes, ask about the date").
    case draft(note: String?)
    case shorter
    case friendlier
    case moreFormal

    var request: String {
        switch self {
        case .draft(let note?) where !note.isEmpty: "Write my reply. What I want to say: \(note)"
        case .draft: "Write a short, helpful reply to the latest message."
        case .shorter: "Rewrite my draft below to be shorter. Keep every fact and question."
        case .friendlier: "Rewrite my draft below to sound warmer and friendlier, without adding new content."
        case .moreFormal: "Rewrite my draft below to sound more formal and polished, without adding new content."
        }
    }
}

/// What a model receives: fixed instructions plus the task text. Kept as plain data so
/// every provider gets the same prompt and tests can read exactly what would be sent.
public struct ModelRequest: Hashable, Sendable {
    public enum Task: String, Sendable { case summary, labels, reply, answer }
    public var task: Task
    public var instructions: String
    public var prompt: String
}

/// One implementation per provider. Each turns a request into the matching result type.
public protocol MailLanguageModel: Sendable {
    /// Shown in the UI ("on this Mac", "by Claude").
    var attribution: String { get }
    /// How many characters of conversation fit comfortably in one request.
    var transcriptBudget: Int { get }
    func summary(_ request: ModelRequest) async throws -> ThreadSummary
    func labels(_ request: ModelRequest) async throws -> [String]
    func reply(_ request: ModelRequest) async throws -> String
    func answer(_ request: ModelRequest) async throws -> MailAnswer
    /// Three short replies, one per line. The default asks for text and splits it.
    func suggestions(_ request: ModelRequest) async throws -> [String]
    /// An answer, handing over the text written so far as it comes in. The default waits
    /// for the whole answer.
    func answer(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> MailAnswer
}

extension MailLanguageModel {
    public func answer(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> MailAnswer {
        try await answer(request)
    }

    public func suggestions(_ request: ModelRequest) async throws -> [String] {
        MailIntelligence.cleanedSuggestions(try await reply(request))
    }
}

/// An answer about the person's mail, citing the conversations it came from (1-based).
public struct MailAnswer: Hashable, Sendable {
    public var text: String
    public var sources: [Int]

    public init(text: String, sources: [Int]) {
        self.text = text
        self.sources = sources
    }
}

/// Summaries, labels and replies for a conversation. Prompts are built here, once, for
/// every provider; the providers only transport them.
public actor MailIntelligence {
    public nonisolated let model: any MailLanguageModel

    public init(model: any MailLanguageModel) { self.model = model }

    public func summarize(_ thread: MailThread, bodies: [String: MessageBody], me: EmailAddress) async throws -> ThreadSummary {
        let request = Self.summaryRequest(thread, bodies: bodies, me: me, budget: model.transcriptBudget)
        var summary = try await model.summary(request)
        summary.headline = summary.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        summary.points = summary.points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(4).map { $0 }
        if let action = summary.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty, action.lowercased() != "none" {
            summary.action = action
        } else {
            summary.action = nil
        }
        return summary
    }

    public func suggestLabels(_ thread: MailThread, bodies: [String: MessageBody], existing: [String], current: [String]) async throws -> [String] {
        let request = Self.labelRequest(thread, bodies: bodies, existing: existing, budget: model.transcriptBudget)
        return Self.normalizedLabels(try await model.labels(request), existing: existing, current: current)
    }

    /// `style` is how the person writes (from their writing profile), so drafts sound like them.
    public func write(_ instruction: WriteInstruction, thread: MailThread, bodies: [String: MessageBody],
                      me: EmailAddress, draft: String, style: String? = nil) async throws -> String {
        let request = Self.replyRequest(instruction, thread: thread, bodies: bodies, me: me, draft: draft,
                                        style: style, budget: model.transcriptBudget)
        return try await model.reply(request).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Three short, different answers to the latest message ("Sounds good!", "Can't make it",
    /// "Let me check"), in the person's own style. Tapping one drafts the full reply.
    public func suggestReplies(_ thread: MailThread, bodies: [String: MessageBody], me: EmailAddress,
                               style: String? = nil) async throws -> [String] {
        let request = Self.suggestionsRequest(thread, bodies: bodies, me: me, style: style, budget: model.transcriptBudget)
        return Self.cleanedSuggestions(try await model.suggestions(request).joined(separator: "\n"))
    }

    static func suggestionsRequest(_ thread: MailThread, bodies: [String: MessageBody], me: EmailAddress,
                                   style: String?, budget: Int) -> ModelRequest {
        // No sample replies here: a small model copies them word for word, whatever the mail says.
        let latest = thread.latest
        let latestText = String(Transcript.clean(bodies[latest.id]?.text ?? latest.body?.text ?? latest.snippet).prefix(1_500))
        return ModelRequest(
            task: .reply,
            instructions: """
            You suggest three short replies \(me.displayName) could send to the latest message. Read what that message \
            actually says or asks and answer it: each reply is 2 to 6 words that only make sense for this message, \
            picking up its question, plan, time or news in your own words. The three go in different directions. \
            Never a one-word reply or one that would fit any email. Use the language of the latest message. \
            Write one per line, with no numbering, quotes or greeting.
            """ + (style.map { "\n\nTone: " + $0.components(separatedBy: "\n").filter { $0.contains("casual") || $0.contains("polished") || $0.contains("emoji") || $0.contains("exclamation") }.joined(separator: " ") } ?? ""),
            prompt: "The conversation, oldest first:\n\n" + Transcript.build(thread, bodies: bodies, budget: min(budget, 6_000))
                + "\n\n===\n\nThe latest message, from \(latest.from.displayName), to answer:\n\n" + latestText
        )
    }

    /// One suggestion per line; numbering, bullets and quotes removed; at most three, no repeats.
    static func cleanedSuggestions(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.components(separatedBy: .newlines)
            .map { line in
                var text = line.trimmingCharacters(in: .whitespaces)
                while let first = text.first, "-•*0123456789.)".contains(first) { text.removeFirst(); text = text.trimmingCharacters(in: .whitespaces) }
                return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' "))
            }
            .filter { !$0.isEmpty && $0.count <= 60 && !isBare($0) && seen.insert($0.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    /// A single word ("yeah", "Sure!") fits any email, so it isn't worth a button. Chinese and
    /// Japanese write without spaces, so there it's about length instead.
    static func isBare(_ text: String) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).count < 2 else { return false }
        let spaceless = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        return spaceless ? text.count < 4 : true
    }

    /// Answers a question from the given conversations only, citing which ones it used.
    public func ask(_ question: String, about threads: [(MailThread, [String: MessageBody])], me: EmailAddress,
                    facts: String = "", partial: (@Sendable (String) async -> Void)? = nil) async throws -> MailAnswer {
        let request = Self.answerRequest(question, threads: threads, me: me, budget: model.transcriptBudget, facts: facts)
        var answer = if let partial { try await model.answer(request, partial: partial) } else { try await model.answer(request) }
        answer.text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only cite conversations that exist, each once.
        var seen = Set<Int>()
        answer.sources = answer.sources.filter { (1...max(threads.count, 1)).contains($0) && $0 <= threads.count && seen.insert($0).inserted }
        return answer
    }

    // MARK: Prompts

    static func answerRequest(_ question: String, threads: [(MailThread, [String: MessageBody])], me: EmailAddress, budget: Int,
                              facts: String = "") -> ModelRequest {
        let share = max((budget - facts.count) / max(threads.count, 1), 400)
        let numbered = threads.enumerated().map { index, item in
            "[\(index + 1)]\n" + Transcript.build(item.0, bodies: item.1, budget: share)
        }.joined(separator: "\n\n=====\n\n")
        let known = facts.isEmpty ? "" : "What Margin knows right now:\n\(facts)\n\n"
        return ModelRequest(
            task: .answer,
            instructions: """
            You answer questions about \(me.displayName)'s email and day, using only what's given: the facts \
            Margin knows (meetings, bills, mail that needs a reply) and the numbered conversations. \
            Answer in the language of the question.

            Answer only what was asked. Use a fact or conversation only when it answers the question; a \
            question about meetings gets meetings, not bills or replies owed. Never pad the answer with \
            other things you were given, counts you weren't given, or remarks about what you left out.

            Format, in Markdown:
            - Start with one short sentence that answers the question directly.
            - Three or more things: put each on its own line starting with "- ", short, with the useful \
            detail first (time, who, amount), for example "- **Tue 10:00** Design review with Noor".
            - Use **bold** only for the key detail of a line. No headings, no tables.
            - Under 80 words unless the question asks for more.

            Facts marked with [n] are conversation n. Ignore spam, scams and adverts unless asked about them. \
            If the answer isn't there, say so plainly in one sentence. "sources" lists only the numbers of \
            conversations you actually used for the answer; leave it empty when none helped.
            """,
            prompt: "Question: \(question)\n\n" + known + "Conversations:\n\n" + (numbered.isEmpty ? "(none found)" : numbered)
        )
    }

    static func summaryRequest(_ thread: MailThread, bodies: [String: MessageBody], me: EmailAddress, budget: Int) -> ModelRequest {
        ModelRequest(
            task: .summary,
            instructions: """
            You summarize email conversations for \(me.displayName) <\(me.address)>. Be brief and concrete. \
            Write in the language of the conversation. Never invent facts. "action" is what \(me.displayName) \
            is asked to do, or empty when nothing is asked.
            """,
            prompt: "Summarize this conversation.\n\n" + Transcript.build(thread, bodies: bodies, budget: budget)
        )
    }

    /// The group a conversation belongs in, from `groups`, or nil when none fits.
    public func classify(_ thread: MailThread, bodies: [String: MessageBody], groups: [EmailGroup]) async throws -> EmailGroup? {
        let answer = try await model.reply(Self.groupRequest(thread, bodies: bodies, groups: groups, budget: min(model.transcriptBudget, 4000)))
        return Self.matchGroup(answer, in: groups)
    }

    static func groupRequest(_ thread: MailThread, bodies: [String: MessageBody], groups: [EmailGroup], budget: Int) -> ModelRequest {
        let list = groups.map { "- \($0.name): \($0.detail)" }.joined(separator: "\n")
        return ModelRequest(
            task: .reply,
            instructions: """
            You sort email into one of the person's groups. Answer with the group's name exactly as written, \
            and nothing else. Answer None when no group clearly fits.
            """,
            prompt: "Groups:\n\(list)\n\nWhich group does this conversation belong in?\n\n" + Transcript.build(thread, bodies: bodies, budget: budget)
        )
    }

    /// Finds the group a model named, forgiving quotes, case and trailing punctuation.
    static func matchGroup(_ answer: String, in groups: [EmailGroup]) -> EmailGroup? {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.*`"))).lowercased()
        guard !cleaned.isEmpty, cleaned != "none" else { return nil }
        return groups.first { $0.name.lowercased() == cleaned }
            ?? groups.first { cleaned.hasPrefix($0.name.lowercased()) }
    }

    static func labelRequest(_ thread: MailThread, bodies: [String: MessageBody], existing: [String], budget: Int) -> ModelRequest {
        let known = existing.isEmpty ? "none yet" : existing.joined(separator: ", ")
        return ModelRequest(
            task: .labels,
            instructions: """
            You file email conversations under short labels of one or two words, like "Travel", "Invoices" or \
            "Hiring". Prefer a label from the existing list when one fits. Suggest at most three; suggest none \
            when nothing fits well.
            """,
            prompt: "Existing labels: \(known)\n\nSuggest labels for this conversation.\n\n"
                + Transcript.build(thread, bodies: bodies, budget: budget)
        )
    }

    static func replyRequest(_ instruction: WriteInstruction, thread: MailThread, bodies: [String: MessageBody],
                             me: EmailAddress, draft: String, style: String? = nil, budget: Int) -> ModelRequest {
        var prompt = instruction.request
        if case .draft = instruction {} else { prompt += "\n\nMy draft:\n\(draft)" }
        prompt += "\n\nThe conversation, oldest first:\n\n" + Transcript.build(thread, bodies: bodies, budget: budget)
        return ModelRequest(
            task: .reply,
            instructions: """
            You write email replies for \(me.displayName). Write only the body of the email: no subject line, \
            no quoted text, no placeholders like [Name]. Match the language and tone of the conversation, keep \
            it short, and sign off as \(me.displayName.split(separator: " ").first.map(String.init) ?? me.displayName). \
            Only answer what this conversation says: never bring in subjects, complaints or facts that aren't in it.
            """ + (style.map { "\n\n" + $0 } ?? ""),
            prompt: prompt
        )
    }

    /// Title Case, at most 24 characters, no repeats, an existing label's spelling when it
    /// matches one, nothing the thread already has, at most three.
    static func normalizedLabels(_ raw: [String], existing: [String], current: [String]) -> [String] {
        var seen = Set(current.map { $0.lowercased() })
        var result: [String] = []
        for label in raw {
            let cleaned = label.trimmingCharacters(in: CharacterSet(charactersIn: " #\"'.").union(.whitespacesAndNewlines))
            guard !cleaned.isEmpty, cleaned.count <= 24 else { continue }
            let spelled = existing.first { $0.lowercased() == cleaned.lowercased() }
                ?? cleaned.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            guard seen.insert(spelled.lowercased()).inserted else { continue }
            result.append(spelled)
            if result.count == 3 { break }
        }
        return result
    }
}

/// The conversation as plain text, newest messages kept first when it has to be cut.
public enum Transcript {
    public static func build(_ thread: MailThread, bodies: [String: MessageBody], budget: Int) -> String {
        var parts: [String] = []
        var used = 0
        for message in thread.messages.reversed() {
            let text = clean(bodies[message.id]?.text ?? message.body?.text ?? message.snippet)
            let header = "From: \(message.from.displayName) <\(message.from.address)>\nDate: \(MailDate.format(message.date))\nSubject: \(message.subject)\n\n"
            var part = header + text
            let room = budget - used
            if part.count > room {
                guard room > header.count + 200 else { break }
                part = String(part.prefix(room)) + "…"
            }
            parts.insert(part, at: 0)
            used += part.count
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    /// Drops quoted history ("> …", "On … wrote:") and signatures, which repeat what's already there.
    static func clean(_ text: String) -> String {
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "--" || trimmed == "-- " { break }
            if trimmed.hasPrefix(">") { continue }
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
