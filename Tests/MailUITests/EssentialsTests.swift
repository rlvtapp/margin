import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct EssentialsTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    @Test func rulesMatchTheFieldTheyName() {
        let message = MailMessage(id: "1", mailboxID: "INBOX", from: EmailAddress(name: "Kettle", address: "news@kettle.example"),
                                  to: [EmailAddress(address: "alex@example.com")], subject: "Your weekly digest", date: Date())
        #expect(MailRule(field: .from, contains: "kettle", action: .archive).matches(message))
        #expect(MailRule(field: .subject, contains: "DIGEST", action: .archive).matches(message))
        #expect(MailRule(field: .to, contains: "alex@", action: .archive).matches(message))
        #expect(!MailRule(field: .subject, contains: "invoice", action: .archive).matches(message))
        #expect(!MailRule(field: .from, contains: "  ", action: .archive).matches(message))
    }

    @Test func newMailFromABlockedSenderLeavesTheInboxBeforeAlerts() async {
        let model = await model()
        model.applyInboxRules() // the first run only remembers what's there
        let thread = try! #require(model.inboxThreads(nil).first)
        model.blockedSenders = [thread.latest.from.address.lowercased()]
        // A new message from them arrives.
        var newer = thread
        var message = thread.latest
        message.id = "brand-new"
        newer.messages.append(message)
        if let account = thread.accountID, let index = model.inboxes[account]?.firstIndex(where: { $0.id == thread.id }) {
            model.inboxes[account]?[index] = newer
        }
        model.applyInboxRules()
        #expect(!model.inboxThreads(nil).contains { $0.id == thread.id })
    }

    @Test func existingMailIsLeftAloneOnTheFirstRun() async {
        let model = await model()
        let before = model.inboxThreads(nil).count
        model.mailRules = [MailRule(field: .subject, contains: "", action: .trash), MailRule(field: .from, contains: "@", action: .archive)]
        model.applyInboxRules()
        #expect(model.inboxThreads(nil).count == before)
    }

    @Test func connectionProblemsWaitInTheOutboxOthersDont() {
        #expect(MailError.isConnectionProblem(MailError.timedOut))
        #expect(MailError.isConnectionProblem(URLError(.notConnectedToInternet)))
        #expect(!MailError.isConnectionProblem(MailError.authenticationFailed("no")))
        #expect(!MailError.isConnectionProblem(MailError.serverRejected("550")))
    }
}
