import Foundation
import Testing
@testable import MailCore

/// Sorting a batch of conversations with one request, as an AI app does over MCP.
@Suite struct SortingBatchTests {
    let groups = [
        EmailGroup(name: "Travel", detail: "Trips and bookings."),
        EmailGroup(name: "Bills to Pay", detail: "Invoices to pay."),
    ]

    func thread(_ id: String, subject: String, snippet: String) -> MailThread {
        let message = MailMessage(id: id, mailboxID: "INBOX", messageID: id,
                                  from: EmailAddress(name: "Noor Haddad", address: "noor@post.example"),
                                  to: [EmailAddress(name: "Alex", address: "alex@home.example")],
                                  subject: subject, date: Date(timeIntervalSince1970: 0), snippet: snippet)
        return MailThread(id: id, messages: [message])
    }

    @Test func oneRequestSortsTheWholeBatch() async throws {
        let fake = FakeModel()
        fake.replyAnswer = "1: Travel\n2. none\n3) \"Bills to pay\"\n9: Travel\nSure, here you go"
        let batch = [
            thread("a", subject: "Lisbon in May?", snippet: "Flights are cheap"),
            thread("b", subject: "Coffee?", snippet: "Tuesday works"),
            thread("c", subject: "Invoice 42", snippet: "Due Friday\nPay by card"),
        ]
        let picked = try await MailIntelligence(model: fake).classify(batch: batch, groups: groups)
        #expect(picked == ["a": groups[0], "c": groups[1]])

        let request = try #require(fake.requests.only)
        #expect(request.prompt.contains("1. From: Noor Haddad"))
        #expect(request.prompt.contains("Subject: Invoice 42"))
        // Previews stay on one line.
        #expect(request.prompt.contains("Preview: Due Friday Pay by card"))
    }

    @Test func previewsShrinkToFitTheBudget() {
        let long = String(repeating: "word ", count: 400)
        let batch = (0..<12).map { thread("\($0)", subject: "Hello", snippet: long) }
        let request = MailIntelligence.batchGroupRequest(batch, groups: groups, budget: 6_000)
        #expect(request.prompt.count < 7_000)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
