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
    /// A rule for new mail from the person's own words. The default asks for JSON and reads it.
    func ruleParts(_ request: ModelRequest) async throws -> RuleParts
    /// "3: Travel" lines for a batch of numbered conversations. The default asks for text.
    func groupLines(_ request: ModelRequest) async throws -> String
    /// A verdict per numbered conversation of a batch. The default asks for JSON and reads it.
    func verdicts(_ request: ModelRequest) async throws -> [Int: MailVerdict]
    /// A yes or no. The default asks for JSON and reads it.
    func yesOrNo(_ request: ModelRequest) async throws -> Bool
    /// What to look up for a question. The default asks for JSON and reads it.
    func askPlan(_ request: ModelRequest) async throws -> AskPlan
    /// A draft, handing over the text written so far as it comes in. The default waits for the
    /// whole draft.
    func reply(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> String
}

extension MailLanguageModel {
    public func reply(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        let text = try await reply(request)
        await partial(text)
        return text
    }

    public func ruleParts(_ request: ModelRequest) async throws -> RuleParts {
        try RuleParts.parse(try await reply(request))
    }

    public func groupLines(_ request: ModelRequest) async throws -> String {
        try await reply(request)
    }

    public func verdicts(_ request: ModelRequest) async throws -> [Int: MailVerdict] {
        MailIntelligence.parseVerdicts(try await reply(request))
    }

    public func yesOrNo(_ request: ModelRequest) async throws -> Bool {
        MailIntelligence.parseAnswer(try await reply(request))
    }

    public func askPlan(_ request: ModelRequest) async throws -> AskPlan {
        MailIntelligence.parsePlan(try await reply(request))
    }

    public func answer(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> MailAnswer {
        try await answer(request)
    }

    public func suggestions(_ request: ModelRequest) async throws -> [String] {
        MailIntelligence.cleanedSuggestions(try await reply(request))
    }
}

/// What Ask looks up for a question, as the model decides: words to search saved mail for
/// (empty when what Margin already knows answers it), and whether it's about the calendar.
public struct AskPlan: Hashable, Sendable {
    public var search: String
    public var calendar: Bool
    /// The days the question is about (ISO 8601, as the model wrote them), for a calendar
    /// question; nil when the model gave none.
    public var from: String?
    public var to: String?

    public init(search: String, calendar: Bool, from: String? = nil, to: String? = nil) {
        self.search = search
        self.calendar = calendar
        self.from = from
        self.to = to
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
        if let action = summary.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
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
                      me: EmailAddress, draft: String, style: String? = nil,
                      partial: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        let request = Self.replyRequest(instruction, thread: thread, bodies: bodies, me: me, draft: draft,
                                        style: style, budget: model.transcriptBudget)
        let text = if let partial { try await model.reply(request, partial: partial) } else { try await model.reply(request) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            Write one per line, with no numbering, quotes or greeting. The replies are from \(me.displayName) to the \
            sender, so never address \(me.displayName). If nobody would answer the latest message (a notice, receipt, \
            confirmation, alert or other automated mail), write nothing at all.
            """ + (style.map { "\n\nHow \(me.displayName) writes:\n" + $0 } ?? ""),
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
                    facts: String = "", style: String = "", partial: (@Sendable (String) async -> Void)? = nil) async throws -> MailAnswer {
        var request = Self.answerRequest(question, threads: threads, me: me, budget: model.transcriptBudget, facts: facts)
        // The person's own preferences (length, instructions) come last, so they win.
        if !style.isEmpty { request.instructions += "\n\n" + style }
        var answer = if let partial { try await model.answer(request, partial: partial) } else { try await model.answer(request) }
        answer.text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only conversations that exist, each once. Which ones the answer used is the model's call.
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
            You answer questions about \(me.displayName)'s email, calendar and day, using only what's given: the \
            facts Margin knows (the calendar as it was looked up for this question, meetings, bills, mail that \
            needs a reply) and the numbered conversations. Answer in the language of the question. A calendar \
            looked up for the question is the whole calendar for those days: answer calendar questions from it, \
            not from invitations in the mail.

            Answer only what was asked. Use a fact or conversation only when it answers the question; a \
            question about meetings gets meetings, not bills or replies owed, and a question about what \
            needs a reply gets the mail that needs a reply, not meetings. When the facts say "none" for \
            what was asked, say that nothing does, in one sentence, and stop. Never pad the answer with \
            other things you were given, counts you weren't given, or remarks about what you left out.

            Use only names, times and places that are written in the facts or conversations, exactly as \
            written there. Never add a person, company or detail that isn't.

            Format, in Markdown:
            - Start with one short sentence that answers the question directly.
            - Three or more things: put each on its own line starting with "- ", short, with the useful \
            detail first (the time, the person or the amount) in bold.
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

    /// How many conversations go into one sorting request: fewer for a model with a small
    /// context window (Apple's on this Mac: 20 take about 3 seconds), more for the rest.
    public nonisolated var sortingBatchSize: Int { sortsInParallel ? 30 : 20 }

    /// How many conversations go into one request for verdicts: Apple's model on this Mac stops
    /// after the first few of a batch, so it reads one at a time (under a second each).
    public nonisolated var verdictBatchSize: Int { sortsInParallel ? 20 : 1 }

    /// Whether a few sorting requests can run at once; Apple's model on this Mac takes one
    /// at a time.
    public nonisolated var sortsInParallel: Bool { model.transcriptBudget >= 10_000 }

    /// The group for each of a batch of conversations, by conversation id; a conversation the
    /// model left out, or put in no group, isn't in the result. One request for the whole
    /// batch, from what the list shows (sender, subject, preview), the way an AI app sorts
    /// over MCP: no bodies to download and no request per conversation.
    public func classify(batch threads: [MailThread], groups: [EmailGroup]) async throws -> [String: EmailGroup] {
        guard !threads.isEmpty else { return [:] }
        let request = Self.batchGroupRequest(threads, groups: groups, budget: min(model.transcriptBudget, 12_000))
        return Self.matchGroups(try await model.groupLines(request), threads: threads, groups: groups)
    }

    /// What the model reads in each conversation of a batch (`MailVerdict`), by conversation
    /// id; ones it left out get none. One request for the whole batch, from what the list shows.
    public func judge(batch threads: [MailThread], me: [EmailAddress]) async throws -> [String: MailVerdict] {
        guard !threads.isEmpty else { return [:] }
        let request = Self.verdictRequest(threads, me: me, budget: min(model.transcriptBudget, 12_000))
        var found: [String: MailVerdict] = [:]
        for (number, verdict) in try await model.verdicts(request) where (1...threads.count).contains(number) {
            found[threads[number - 1].id] = verdict
        }
        return found
    }

    /// What to look up for a question (`AskPlan`), for assistants that can't call tools.
    /// `now` lets the model work out which days "this week" or "tomorrow" are.
    public func plan(_ question: String, now: String = "") async throws -> AskPlan {
        try await model.askPlan(ModelRequest(
            task: .reply,
            instructions: """
            The person asks about their email or their calendar. Decide what to look up. "search": a few words to \
            find the mail in their saved email (names, places, things, in the language that mail would be written \
            in), or empty when the question is only about their calendar, bills still to pay, mail they owe a reply, \
            or mail waiting for an answer: those are already known, and the calendar is read directly, not searched \
            for in mail. "calendar": true when it's about their calendar, meetings, schedule or free time. "from" \
            and "to": for a calendar question, the first and last day it's about (ISO 8601 dates, "to" included), \
            worked out from now\(now.isEmpty ? "" : " (\(now))"); leave them out for other questions. Answer with \
            JSON only: {"search": "", "calendar": true, "from": "2026-03-02", "to": "2026-03-08"}.
            """,
            prompt: String(question.prefix(1_000))
        ))
    }

    static func parsePlan(_ answer: String) -> AskPlan {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] else {
            return AskPlan(search: "", calendar: false)
        }
        let day = { (key: String) in (object[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        return AskPlan(search: (object["search"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                       calendar: object["calendar"] as? Bool ?? false, from: day("from"), to: day("to"))
    }

    /// Whether what someone wrote says a file is attached or enclosed, in any language.
    public func mentionsAttachment(_ text: String) async throws -> Bool {
        try await model.yesOrNo(ModelRequest(
            task: .reply,
            instructions: """
            You check an email before it's sent. Say whether the writer says they are sending a file, document or \
            picture with this email (attached, enclosed, included, in any language). A file someone else sent \
            earlier doesn't count. Answer with JSON only: {"answer": true} or {"answer": false}.
            """,
            prompt: String(text.prefix(4_000))
        ))
    }

    /// Reads `{"answer": true}`, ignoring anything around it.
    static func parseAnswer(_ answer: String) -> Bool {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any] else { return false }
        return object["answer"] as? Bool ?? false
    }

    static func verdictRequest(_ threads: [MailThread], me: [EmailAddress], budget: Int) -> ModelRequest {
        let preview = max(80, min(400, budget / max(threads.count, 1) - 150))
        let conversations = threads.enumerated().map { index, thread in
            let snippet = thread.latest.snippet.split(whereSeparator: \.isNewline).joined(separator: " ")
            return """
            \(index + 1). From: \(thread.latest.from.headerValue)
            Subject: \(thread.subject)
            Preview: \(snippet.prefix(preview))
            """
        }.joined(separator: "\n\n")
        let names = me.map(\.headerValue).joined(separator: ", ")
        return ModelRequest(
            task: .reply,
            instructions: """
            You read email for \(names). For each numbered conversation, judge its latest message: \
            "automated" when a system or a company's automation sent it (notices, alerts, receipts, sign-in codes, \
            account and service mail) rather than a person writing to them; "reply" when a person is waiting on an \
            answer from them; "pay" when it asks them to pay something still open (a bill or payment request, not a \
            receipt or an invoice already paid automatically). Answer with a JSON array only, one object per \
            conversation: {"n": 3, "automated": true, "reply": false, "pay": false}.
            """,
            prompt: "Conversations:\n\n\(conversations)"
        )
    }

    /// Reads the JSON array of verdicts, ignoring anything around it.
    static func parseVerdicts(_ answer: String) -> [Int: MailVerdict] {
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end,
              let items = try? JSONDecoder().decode([VerdictLine].self, from: Data(answer[start...end].utf8)) else { return [:] }
        var found: [Int: MailVerdict] = [:]
        for item in items { found[item.n] = MailVerdict(automated: item.automated, needsReply: item.reply, asksToPay: item.pay) }
        return found
    }

    struct VerdictLine: Decodable {
        var n: Int
        var automated: Bool
        var reply: Bool
        var pay: Bool
    }

    static func batchGroupRequest(_ threads: [MailThread], groups: [EmailGroup], budget: Int) -> ModelRequest {
        let list = groups.map { "- \($0.name): \($0.detail)" }.joined(separator: "\n")
        // What's left after the groups, shared out over the conversations.
        let preview = max(80, min(300, (budget - list.count) / max(threads.count, 1) - 150))
        let conversations = threads.enumerated().map { index, thread in
            let snippet = thread.latest.snippet.split(whereSeparator: \.isNewline).joined(separator: " ")
            return """
            \(index + 1). From: \(thread.latest.from.headerValue)
            Subject: \(thread.subject)
            Preview: \(snippet.prefix(preview))
            """
        }.joined(separator: "\n\n")
        return ModelRequest(
            task: .reply,
            instructions: """
            You sort email into the person's groups. For each numbered conversation, write one line: its number, \
            a colon, and the group's name exactly as written, like "3: Travel". Leave out a conversation no group \
            clearly fits. Write nothing else.
            """,
            prompt: "Groups:\n\(list)\n\nConversations:\n\n\(conversations)"
        )
    }

    /// Reads "3: Travel" lines back into a group per conversation id.
    static func matchGroups(_ answer: String, threads: [MailThread], groups: [EmailGroup]) -> [String: EmailGroup] {
        var found: [String: EmailGroup] = [:]
        for line in answer.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-*#")))
            let digits = trimmed.prefix(while: \.isNumber)
            guard let number = Int(digits), (1...threads.count).contains(number) else { continue }
            let rest = trimmed.dropFirst(digits.count).drop { ":.)-–— \t".contains($0) }
            if let group = matchGroup(String(rest), in: groups) { found[threads[number - 1].id] = group }
        }
        return found
    }

    /// Finds the group a model named, forgiving quotes, case and trailing punctuation.
    static func matchGroup(_ answer: String, in groups: [EmailGroup]) -> EmailGroup? {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.*`"))).lowercased()
        guard !cleaned.isEmpty else { return nil }
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
            Only answer what this conversation says: never bring in subjects, complaints or facts that aren't in it. \
            Never pad: say what's needed once, without repeating thanks or enthusiasm and without filler.
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
