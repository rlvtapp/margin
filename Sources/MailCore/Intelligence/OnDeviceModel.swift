import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (Apple Intelligence). Nothing leaves the device. Available on
/// macOS and iOS 26 or later, on hardware that supports it, when the person has it turned on.
public enum OnDeviceModel {
    static var settingsApp: String {
        #if os(macOS)
        "System Settings"
        #else
        "Settings"
        #endif
    }

    /// "Mac" or "device", for "on this Mac" and "on this device".
    public static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "device"
        #endif
    }

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why it can't be used, in plain words, or nil when it can.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible):
                #if os(macOS)
                return String(localized: "This Mac doesn't support Apple Intelligence.")
                #else
                return String(localized: "This device doesn't support Apple Intelligence.")
                #endif
            case .unavailable(.appleIntelligenceNotEnabled):
                #if os(macOS)
                return String(localized: "Turn on Apple Intelligence in System Settings to use it.")
                #else
                return String(localized: "Turn on Apple Intelligence in Settings to use it.")
                #endif
            case .unavailable(.modelNotReady): return String(localized: "Apple Intelligence is still downloading. Try again later.")
            case .unavailable: return String(localized: "Apple Intelligence isn't available right now.")
            }
        }
        #endif
        #if os(macOS)
        return String(localized: "Needs macOS 26 or later with Apple Intelligence.")
        #else
        return String(localized: "Needs iOS 26 or later with Apple Intelligence.")
        #endif
    }

    static func make() -> (any MailLanguageModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), isAvailable { return AppleModel() }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
struct AppleModel: MailLanguageModel {
    var attribution: String {
        #if os(macOS)
        String(localized: "on this Mac", comment: "Who wrote an assistant answer, as in “Summary on this Mac”")
        #else
        String(localized: "on this device", comment: "Who wrote an assistant answer, as in “Summary on this device”")
        #endif
    }
    /// The on-device model has a small context window; keep the conversation short.
    var transcriptBudget: Int { 6_000 }

    @Generable struct Summary {
        @Guide(description: "One sentence: what this conversation is about and where it stands.")
        var headline: String
        @Guide(description: "Up to four short facts worth knowing.", .count(0...4))
        var points: [String]
        @Guide(description: "What the reader is asked to do, or an empty string when nothing is asked.")
        var action: String
    }

    @Generable struct Labels {
        @Guide(description: "Zero to three labels of one or two words.", .count(0...3))
        var labels: [String]
    }

    @Generable struct Reply {
        @Guide(description: "The email body only.")
        var body: String
    }

    @Generable struct Suggestions {
        @Guide(description: "Three replies of 2 to 6 words that answer what the latest message says or asks, each going a different way.", .count(3))
        var replies: [String]
    }

    func suggestions(_ request: ModelRequest) async throws -> [String] {
        try await plainErrors { try await session(request).respond(to: request.prompt, generating: Suggestions.self).content.replies }
    }

    @Generable struct Answer {
        @Guide(description: "The answer in Markdown: a direct first sentence, then \"- \" lines for lists.")
        var answer: String
        @Guide(description: "Numbers of the conversations used.")
        var sources: [Int]
    }

    func answer(_ request: ModelRequest) async throws -> MailAnswer {
        try await plainErrors {
            let result = try await session(request).respond(to: request.prompt, generating: Answer.self).content
            return MailAnswer(text: result.answer, sources: result.sources)
        }
    }

    func reply(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        try await plainErrors {
            var latest = ""
            for try await snapshot in session(request).streamResponse(to: request.prompt, generating: Reply.self) {
                if let body = snapshot.content.body, body != latest {
                    latest = body
                    await partial(body)
                }
            }
            return latest
        }
    }

    func answer(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> MailAnswer {
        try await plainErrors {
            var latest = MailAnswer(text: "", sources: [])
            for try await snapshot in session(request).streamResponse(to: request.prompt, generating: Answer.self) {
                let content = snapshot.content
                if let text = content.answer, text != latest.text {
                    latest.text = text
                    await partial(text)
                }
                if let sources = content.sources { latest.sources = sources }
            }
            return latest
        }
    }

    func summary(_ request: ModelRequest) async throws -> ThreadSummary {
        try await plainErrors {
            let result = try await session(request).respond(to: request.prompt, generating: Summary.self).content
            return ThreadSummary(headline: result.headline, points: result.points, action: result.action)
        }
    }

    func labels(_ request: ModelRequest) async throws -> [String] {
        try await plainErrors { try await session(request).respond(to: request.prompt, generating: Labels.self).content.labels }
    }

    func reply(_ request: ModelRequest) async throws -> String {
        try await plainErrors { try await session(request).respond(to: request.prompt, generating: Reply.self).content.body }
    }

    /// The framework's errors, in words someone can act on.
    func plainErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw AssistantError.onDevice(String(localized: "This conversation is too long for the on-device model."))
            case .guardrailViolation, .refusal:
                throw AssistantError.refused
            case .unsupportedLanguageOrLocale:
                throw AssistantError.onDevice(String(localized: "The on-device model doesn't support this language yet."))
            case .assetsUnavailable:
                throw AssistantError.onDevice(String(localized: "Apple Intelligence is still getting ready. Try again in a few minutes."))
            case .rateLimited, .concurrentRequests:
                throw AssistantError.onDevice(String(localized: "Apple Intelligence is busy. Try again in a moment."))
            default:
                throw AssistantError.onDevice(String(localized: "Apple Intelligence couldn't answer this time."))
            }
        } catch let error as AssistantError {
            throw error
        } catch {
            // Errors from the system's model service, such as a missing model on the Simulator.
            throw AssistantError.onDevice(String(localized: "Apple Intelligence couldn't answer this time."))
        }
    }

    /// A fresh session per request: each task stands alone, so no history carries over.
    @Generable struct Rule {
        @Guide(description: "Where to look: from, to or subject.", .anyOf(["from", "to", "subject"]))
        var field: String
        @Guide(description: "The text to look for: an address, a domain like @example.com, a name or a word.")
        var contains: String
        @Guide(description: "What to do with matching new mail.", .anyOf(["archive", "trash", "mark_read", "star", "label", "group", "move", "forward", "answer", "quiet"]))
        var action: String
        @Guide(description: "The folder, label or group name for move, label and group; the address for forward; the reply for answer; empty otherwise.")
        var target: String
        @Guide(description: "A mailbox name, or all.")
        var mailbox: String
    }

    @Generable struct Groups {
        @Guide(description: "One entry per numbered conversation, in order: the group's name exactly as written, or None.")
        var groups: [String]
    }

    /// Sorting asks for a list rather than text: through the plain reply the model sometimes
    /// writes an email instead. Greedy, so the same mail always lands in the same group.
    func groupLines(_ request: ModelRequest) async throws -> String {
        try await plainErrors {
            let result = try await session(request).respond(to: request.prompt, generating: Groups.self,
                                                            options: GenerationOptions(sampling: .greedy)).content
            // It often numbers the entries itself ("3: Travel"); its own number wins.
            return result.groups.enumerated().map { index, entry in
                entry.first?.isNumber == true ? entry : "\(index + 1): \(entry)"
            }.joined(separator: "\n")
        }
    }

    func ruleParts(_ request: ModelRequest) async throws -> RuleParts {
        try await plainErrors {
            let rule = try await session(request).respond(to: request.prompt, generating: Rule.self).content
            return RuleParts(field: rule.field, contains: rule.contains, action: rule.action, target: rule.target, mailbox: rule.mailbox)
        }
    }

    private func session(_ request: ModelRequest) -> LanguageModelSession {
        LanguageModelSession(instructions: request.instructions)
    }
}
#endif
