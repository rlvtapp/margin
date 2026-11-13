import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct RuleExtrasTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.mailRules = []
        return model
    }

    func message(from address: String, lists: Bool = false) -> MailMessage {
        var message = MailMessage(id: UUID().uuidString, mailboxID: "INBOX", from: EmailAddress(name: "Sam", address: address),
                                  to: [EmailAddress(address: "me@example.com")], subject: "Hi", date: Date())
        if lists { message.listHeaders = ["list-id": "<news.example>"] }
        return message
    }

    @Test func rulesThatSendMailHaveSafeguards() async throws {
        let model = await model()
        let rule = UUID()
        let answer = MailRule.Action.answer("Away until Monday")
        #expect(model.mayAutoSend(answer, to: message(from: "sam@kettle.example"), ruleID: rule))
        #expect(!model.mayAutoSend(answer, to: message(from: "no-reply@kettle.example"), ruleID: rule))
        #expect(!model.mayAutoSend(answer, to: message(from: "sam@kettle.example", lists: true), ruleID: rule))
        let mine = try #require(model.accounts.first?.address.address)
        #expect(!model.mayAutoSend(answer, to: message(from: mine), ruleID: rule))
        // Once answered, that sender waits four days.
        model.ruleAnswers["\(rule.uuidString)|sam@kettle.example"] = Date()
        #expect(!model.mayAutoSend(answer, to: message(from: "sam@kettle.example"), ruleID: rule))
        #expect(model.mayAutoSend(answer, to: message(from: "sam@kettle.example"), ruleID: rule, now: Date().addingTimeInterval(5 * 86_400)))
        // Forwards need a real address, and never go back to the sender.
        #expect(model.mayAutoSend(.forward("me2@elsewhere.example"), to: message(from: "sam@kettle.example"), ruleID: rule))
        #expect(!model.mayAutoSend(.forward("sam@kettle.example"), to: message(from: "sam@kettle.example"), ruleID: rule))
        #expect(!model.mayAutoSend(.forward("not an address"), to: message(from: "sam@kettle.example"), ruleID: rule))
    }

    @Test func quietRulesKeepTheAlertAway() async throws {
        let model = await model()
        let thread = try #require(model.inboxThreads(nil).first)
        #expect(!model.isQuietByRule(thread))
        model.mailRules = [MailRule(field: .from, contains: thread.latest.from.address, action: .quiet)]
        #expect(model.isQuietByRule(thread))
        #expect(model.inboxThreads(nil).contains { $0.id == thread.id })   // still in the inbox
    }

    @Test func aSavedRuleCanBeChanged() async throws {
        let model = await model()
        model.mailRules = [MailRule(field: .from, contains: "bank", action: .star)]
        var form = RuleForm(rule: model.mailRules[0])
        #expect(form.editing == model.mailRules[0].id && form.choice == .star && form.contains == "bank")
        form.choice = .answer
        form.name = "Thanks, got it."
        #expect(model.addRule(form))
        #expect(model.mailRules.count == 1)
        #expect(model.mailRules[0].action == .answer("Thanks, got it."))
        #expect(RuleForm(rule: model.mailRules[0]).rule == model.mailRules[0])
        #expect(!MailModel.starterRules.isEmpty)
    }

    @Test func fileTheSameSenderThreeTimesAndARuleIsOffered() async throws {
        let model = await model()
        let thread = try #require(model.inboxThreads(nil).first { $0.accountID != nil && !model.folders(of: $0.accountID!).filter { $0.role == .other }.isEmpty })
        let folder = try #require(model.folders(of: thread.accountID!).first { $0.role == .other })
        #expect(model.ruleSuggestion == nil)
        for _ in 0..<3 { model.noteFiling([thread], into: folder.id) }
        let suggestion = try #require(model.ruleSuggestion)
        #expect(suggestion.form.choice == .move && suggestion.form.name == folder.name && suggestion.form.field == .from)
        #expect(model.addRule(suggestion.form))
        #expect(model.ruleSuggestion == nil)   // a rule does it now
    }

    @Test func agentsNeedSendingPermissionForRulesThatSend() async throws {
        let model = await model()
        var settings = model.connectionSettings
        settings.allowChanges = true
        model.connectionSettings = settings
        let toolbox = MailToolbox(model: model)
        let forward: [String: MCPValue] = ["field": .string("from"), "contains": .string("bank"), "action": .string("forward"), "target": .string("me2@elsewhere.example")]
        await #expect(throws: MCPToolError.self) { try await toolbox.call("create_rule", arguments: forward) }
        settings.allowSending = true
        model.connectionSettings = settings
        _ = try await toolbox.call("create_rule", arguments: forward)
        #expect(model.mailRules.first?.action == .forward("me2@elsewhere.example"))
        _ = try await toolbox.call("create_rule", arguments: ["field": .string("from"), "contains": .string("alerts@"), "action": .string("quiet")])
        #expect(model.mailRules.contains { $0.action == .quiet })
    }
}
