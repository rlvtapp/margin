import Foundation
import Testing
@testable import MailCore

/// An answer shows the conversations the model says it used, and never borrows names from the
/// instructions it was given.
@Suite struct AnswerSourcesTests {
    private let me = EmailAddress(name: "Alex Rivera", address: "alex@example.com")

    private func thread(from: EmailAddress, subject: String, text: String) -> (MailThread, [String: MessageBody]) {
        let message = MailMessage(id: UUID().uuidString, mailboxID: "INBOX", from: from, to: [me], subject: subject, date: Date())
        return (MailThread(id: message.id, messages: [message]), [message.id: MessageBody(text: text, html: nil, attachments: [])])
    }

    @Test func theModelsSourcesAreKeptWhenTheyExist() async throws {
        // Which conversations the answer used is the model's call; only numbers that don't
        // exist, and repeats, are left out.
        final class Citing: MailLanguageModel, @unchecked Sendable {
            var attribution: String { "by fake" }
            var transcriptBudget: Int { 500 }
            func summary(_ request: ModelRequest) async throws -> ThreadSummary { ThreadSummary(headline: "", points: [], action: nil) }
            func labels(_ request: ModelRequest) async throws -> [String] { [] }
            func reply(_ request: ModelRequest) async throws -> String { "" }
            func answer(_ request: ModelRequest) async throws -> MailAnswer { MailAnswer(text: "Sam asked about it.", sources: [2, 2, 7, 1]) }
        }
        let one = thread(from: EmailAddress(name: "Sam Okafor", address: "sam@example.com"), subject: "Invoice", text: "14 seats")
        let two = thread(from: EmailAddress(name: nil, address: "no-reply@signin.example"), subject: "Verify", text: "Code 482913")
        let answer = try await MailIntelligence(model: Citing()).ask("What did Sam ask?", about: [one, two], me: me)
        #expect(answer.sources == [2, 1])
    }

    @Test func theInstructionsCarryNoNamesToCopy() {
        let request = MailIntelligence.answerRequest("What needs a reply from me?", threads: [], me: me, budget: 4000,
                                                     facts: "Mail that needs a reply: none.")
        #expect(!request.instructions.contains("Noor"))
        #expect(request.instructions.contains("exactly as"))
        #expect(request.prompt.contains("Mail that needs a reply: none."))
    }
}
