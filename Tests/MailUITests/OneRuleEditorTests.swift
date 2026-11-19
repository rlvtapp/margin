import Foundation
import MailCore
import Testing
@testable import MailUI

/// One editor for every rule: the same form makes rules kept in Margin and rules kept on the
/// mailbox's server, and moves a rule between them.
@MainActor @Suite(.serialized) struct OneRuleEditorTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.mailRules = []
        return model
    }

    func message(subject: String, attachment: Bool) -> MailMessage {
        MailMessage(id: UUID().uuidString, mailboxID: "INBOX", from: EmailAddress(name: "Billing", address: "billing@shop.example"),
                    to: [EmailAddress(address: "me@example.com")], subject: subject, date: Date(), hasAttachments: attachment)
    }

    @Test func marginRulesMatchEveryConditionAndDoEveryAction() {
        var form = RuleForm(field: .from, contains: "billing@")
        form.subject = "Invoice"
        form.hasAttachment = true
        form.markRead = true
        form.star = true
        form.move = .archive
        let rule = try! #require(form.rule)
        #expect(rule.conditions.count == 2 && rule.hasAttachment)
        #expect(rule.actions == [.archive, .markRead, .star])
        #expect(rule.matches(message(subject: "Invoice 42", attachment: true)))
        #expect(!rule.matches(message(subject: "Invoice 42", attachment: false)))
        #expect(!rule.matches(message(subject: "Hello", attachment: true)))
        #expect(RuleForm(rule: rule).rule?.actions == rule.actions)
    }

    @Test func theSameFormMakesAServerRule() {
        let account = UUID()
        var form = RuleForm(field: .subject, contains: "receipt", accountID: account)
        form.place = .server
        form.move = .folder
        form.folder = "receipts"
        form.markRead = true
        form.star = true
        let server = try! #require(form.serverRule)
        #expect(server.subject == "receipt" && server.moveTo == "receipts" && server.markRead && server.flag && !server.delete)
        #expect(form.rule == nil)   // it's for the server, not Margin
        // Back into the form to change it, keeping its id and name.
        var named = server
        named.id = "7"
        named.name = "Receipts"
        let again = RuleForm(server: named, accountID: account)
        #expect(again.serverRule?.id == "7" && again.serverRule?.name == "Receipts" && again.place == .server)
        // Archiving and Trash are moves too.
        form.move = .archive
        #expect(form.serverRule?.archive == true && form.serverRule?.moveTo == nil)
    }

    @Test func onlyMarginCanLabelAnswerOrKeepQuiet() {
        var form = RuleForm(field: .from, contains: "news@", accountID: UUID())
        form.place = .server
        form.label = "News"
        #expect(form.needsMargin && !form.isComplete)
        form.place = .margin
        #expect(form.isComplete && form.rule?.actions == [.label("News")])
        // A rule for every mailbox can only run in Margin.
        var everywhere = RuleForm(field: .from, contains: "news@")
        everywhere.place = .server
        everywhere.markRead = true
        #expect(!everywhere.isComplete)
    }

    @Test func movingARuleFromMarginToTheServer() async throws {
        let model = await model()
        let account = try #require(model.accounts.first)
        #expect(model.serverRulesSupport(account) == .ready)
        let book = ServerRuleBook()
        await book.load(account, model: model)
        #expect(book.canKeep(account.id))
        let before = book.rules[account.id]?.count ?? 0

        model.mailRules = [MailRule(field: .from, contains: "moving@example.com", action: .markRead, accountID: account.id)]
        var form = RuleForm(rule: model.mailRules[0])
        form.place = .server
        try await model.saveRule(form, book: book)
        #expect(model.mailRules.isEmpty)   // never runs twice
        let saved = try #require(book.rules[account.id]?.first { $0.from == "moving@example.com" })
        #expect(saved.markRead && book.rules[account.id]?.count == before + 1)

        // And back into Margin.
        var back = RuleForm(server: saved, accountID: account.id)
        back.place = .margin
        try await model.saveRule(back, book: book)
        #expect(model.mailRules.count == 1 && model.mailRules[0].actions == [.markRead])
        #expect(book.rules[account.id]?.contains { $0.from == "moving@example.com" } == false)
    }

    @Test func aiAppsCanOnlyChangeSimpleRules() async throws {
        let model = await model()
        var form = RuleForm(field: .from, contains: "a@example.com")
        form.subject = "Report"
        form.markRead = true
        #expect(model.addRule(form))
        let id = try #require(model.mailRules.first?.id)
        await #expect(throws: (any Error).self) {
            _ = try await model.runRuleTool("update_rule", ["id": .string(id.uuidString), "contains": .string("b@")])
        }
        let listed = try #require(try await model.runRuleTool("list_rules", [:]))
        #expect(listed.contains("Report") && listed.contains("conditions"))
    }
}
