import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct RuleUpgradeTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.mailRules = []
        return model
    }

    /// A new email arrives in an inbox conversation, as on the next refresh.
    func arrive(in thread: MailThread, _ model: MailModel, id: String) {
        var newer = thread
        var message = thread.latest
        message.id = id
        newer.messages.append(message)
        model.removeFromInboxes(ids: [thread.id])
        model.restoreToInboxes([newer])
    }

    @Test func createRuleStartsFromTheSenderTheirDomainOrTheSubject() async throws {
        let model = await model()
        let bank = try #require(model.inboxThreads(nil).first { $0.subject.contains("Card payment") })
        let sender = model.ruleForm(for: bank, basis: .sender)
        #expect(sender.field == .from && sender.contains == "notifications@fieldworkbank.example")
        #expect(sender.accountID == bank.accountID && sender.threadID == bank.id)
        #expect(model.ruleForm(for: bank, basis: .domain).contains == "@fieldworkbank.example")
        let subject = model.ruleForm(for: bank, basis: .subject)
        #expect(subject.field == .subject && subject.contains == bank.subject)
        #expect(MailModel.plainSubject("Re: Fwd: Weekly report") == "Weekly report")

        // What it would catch includes the conversation it came from.
        #expect(model.inboxMatches(try #require(sender.condition)).contains { $0.id == bank.id })

        model.startRule(for: bank)
        #expect(model.creatingRule?.contains == "notifications@fieldworkbank.example")
    }

    @Test func aRuleNeedsItsPartsAndAFolderThatExists() async throws {
        let model = await model()
        var form = RuleForm(field: .from, contains: "  ", choice: .star)
        #expect(form.rule == nil)
        form.contains = "bank"
        #expect(form.rule?.action == .star)
        form.choice = .move
        #expect(form.rule == nil)   // a folder is needed
        form.name = "Nowhere"
        #expect(form.rule != nil && model.ruleFolderMissing(form))
        form.name = "archive"
        #expect(!model.ruleFolderMissing(form))

        #expect(model.addRule(form))
        #expect(model.addRule(form))   // the same rule again is kept once
        #expect(model.mailRules.count == 1)
    }

    @Test func theAssistantsRuleIsMatchedToRealNames() async throws {
        let model = await model()
        let form = model.ruleForm(from: RuleParts(field: "from", contains: "@fieldworkbank.example", action: "group", target: "bills to pay", mailbox: "work"))
        #expect(form.choice == .label && form.name == "Bills to Pay")
        #expect(form.accountID == model.accounts.first { $0.label == "Work" }?.id)
        let move = model.ruleForm(from: RuleParts(field: "subject", contains: "digest", action: "move", target: "ARCHIVE"))
        #expect(move.choice == .move && move.name == "Archive" && move.accountID == nil)
        let unknown = model.ruleForm(from: RuleParts(field: "body", contains: "x", action: "explode"))
        #expect(unknown.field == .from && unknown.choice == .archive)
    }

    @Test func ruleMovesCanBeUndoneAndShowInRecentActivity() async throws {
        let model = await model()
        model.applyInboxRules()   // the first run only remembers what's there
        let bank = try #require(model.inboxThreads(nil).first { $0.subject.contains("Card payment") })
        model.mailRules = [MailRule(field: .from, contains: "fieldworkbank", action: .archive)]
        arrive(in: bank, model, id: "new-from-bank")

        model.applyInboxRules()
        #expect(!model.inboxThreads(nil).contains { $0.id == bank.id })
        for _ in 0..<50 where model.notice?.canUndo != true { await Task.yield() }
        #expect(model.notice?.canUndo == true)
        #expect(model.pendingChange?.ruleBatch != nil)
        let entry = try #require(model.ruleActivity.first)
        #expect(entry.subject == bank.subject && !entry.undone)

        model.undo()
        #expect(model.inboxThreads(nil).contains { $0.id == bank.id })
        #expect(model.ruleActivity.first?.undone == true)
    }

    @Test func labelsAndStarsAreLoggedToo() async throws {
        let model = await model()
        model.applyInboxRules()
        let bank = try #require(model.inboxThreads(nil).first { $0.subject.contains("Card payment") })
        model.mailRules = [MailRule(field: .from, contains: "fieldworkbank", action: .label("Money"))]
        arrive(in: bank, model, id: "another-from-bank")
        model.applyInboxRules()
        #expect(model.labels(for: bank).contains("Money"))
        #expect(model.inboxThreads(nil).contains { $0.id == bank.id })
        #expect(model.ruleActivity.first?.action == MailRule.Action.label("Money").title)
    }
}
