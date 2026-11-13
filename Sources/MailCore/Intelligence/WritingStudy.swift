import Foundation

extension MailIntelligence {
    /// A description of how someone writes, from a sample of their own sent mail: what counting
    /// can't find (rhythm, directness, how they ask for things, the words they reach for). Style
    /// only: the request asks for no names, facts or topics, so drafts never borrow content.
    public func studyWriting(_ samples: [String], name: String, language: String?) async throws -> String {
        let text = try await model.reply(Self.studyRequest(samples, name: name, language: language, budget: model.transcriptBudget))
        return Self.cleanedStudy(text)
    }

    static func studyRequest(_ samples: [String], name: String, language: String?, budget: Int) -> ModelRequest {
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
        // As many emails as fit, each cut to a fair share, newest first as given.
        var picked: [String] = []
        var used = 0
        let room = max(budget - 1_500, 1_000)
        for sample in samples {
            let cut = String(sample.prefix(1_200))
            guard used + cut.count <= room else { break }
            picked.append(cut)
            used += cut.count
        }
        let emails = picked.enumerated().map { "--- Email \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n")
        return ModelRequest(
            task: .reply,
            instructions: """
            You study how one person writes email, so an assistant can later write new emails that sound exactly \
            like them. Read the emails they wrote below (their own words; quoted replies are removed)\
            \(languageName.map { ", all in \($0)" } ?? ""). Describe their writing voice in 8 to 12 short bullet points, \
            each starting with "- ": tone and formality (how they address people), sentence length and rhythm, \
            paragraphs, how they open and how they close, words and phrases they use often (quote them exactly, \
            in their own language), how they ask for things and say no, punctuation and capitals, emoji, how \
            direct or warm they are, and what they never do. Be specific to this person; skip anything generic. \
            Describe style only: no names of people or companies, no facts, no topics from the emails. \
            Write the points in English. Answer with the bullet points only.
            """,
            prompt: "\(picked.count) emails written by \(name):\n\n\(emails)"
        )
    }

    /// The bullet points only, at most 14, without a preamble the model may add.
    static func cleanedStudy(_ text: String) -> String {
        let points = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("• ") || $0.hasPrefix("* ") }
            .map { "- " + $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
        let kept = points.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : Array(points.prefix(14))
        return String(kept.joined(separator: "\n").prefix(2_400))
    }
}

extension AssistantProvider {
    /// A stronger model for work done once and kept, like studying how someone writes: worth
    /// more than the quick one everyday mail uses. Nil keeps the assistant's own model.
    public var studyModel: String? {
        switch self {
        case .claude: "claude-sonnet-5-5"
        case .claudeCode: "sonnet"
        default: nil
        }
    }
}
