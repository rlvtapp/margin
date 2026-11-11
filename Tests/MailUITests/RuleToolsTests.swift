import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct RuleToolsTests {
    func model(allowChanges: Bool = true) async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        model.mailRules = []
        var settings = model.connectionSettings
        settings.allowChanges = allowChanges
        model.connectionSettings = settings
        return model
    }

    func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func list(_ toolbox: MailToolbox) async throws -> [[String: Any]] {
        let text = try await toolbox.call("list_rules", arguments: [:])
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    @Test func readingRulesIsAlwaysOnChangingThemNeedsPermission() async throws {
        let model = await model(allowChanges: false)
        let toolbox = MailToolbox(model: model)
        let names = await toolbox.tools().map(\.name)
        #expect(names.contains("list_rules") && names.contains("preview_rule"))
        #expect(!names.contains("create_rule") && !names.contains("update_rule") && !names.contains("delete_rule"))
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("create_rule", arguments: ["field": .string("from"), "contains": .string("bank"), "action": .string("star")])
        }
        #expect(model.mailRules.isEmpty)

        var settings = model.connectionSettings
        settings.allowChanges = true
        model.connectionSettings = settings
        let allowed = await toolbox.tools().map(\.name)
        #expect(allowed.contains("create_rule") && allowed.contains("update_rule") && allowed.contains("delete_rule"))
    }

    @Test func createListUpdateAndDeleteARule() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)

        // "Always mark mail from my bank as important"
        let created = try object(try await toolbox.call("create_rule", arguments: [
            "field": .string("from"), "contains": .string(" fieldworkbank.example "), "action": .string("star"),
        ]))
        let rule = try #require(created["rule"] as? [String: Any])
        let id = try #require(rule["id"] as? String)
        #expect(rule["contains"] as? String == "fieldworkbank.example")
        #expect(rule["action"] as? String == "star")
        #expect(rule["mailbox"] as? String == "all")
        #expect(model.mailRules.count == 1)
        #expect(model.mailRules[0].action == .star)
        #expect((created["note"] as? String)?.contains("already in the inbox") == true)
        #expect(model.notice != nil)

        // The same rule again changes nothing.
        let again = try object(try await toolbox.call("create_rule", arguments: [
            "field": .string("from"), "contains": .string("FieldworkBank.example"), "action": .string("star"),
        ]))
        #expect((again["note"] as? String)?.contains("already exists") == true)
        #expect(model.mailRules.count == 1)

        let listed = try await list(toolbox)
        #expect(listed.count == 1 && listed[0]["id"] as? String == id)

        // Move it into a Home group instead, for one mailbox.
        let updated = try object(try await toolbox.call("update_rule", arguments: [
            "id": .string(id), "action": .string("group"), "target": .string("bills to pay"), "mailbox": .string("Work"),
        ]))
        let changed = try #require(updated["rule"] as? [String: Any])
        #expect(changed["action"] as? String == "group")
        #expect(changed["target"] as? String == "Bills to Pay")
        #expect(changed["mailbox"] as? String == "Work")
        #expect(model.mailRules.count == 1 && model.mailRules[0].id.uuidString == id)
        #expect(model.mailRules[0].action == .label("Bills to Pay"))
        #expect(model.mailRules[0].field == .from && model.mailRules[0].contains == "fieldworkbank.example")

        _ = try await toolbox.call("delete_rule", arguments: ["id": .string(id)])
        #expect(model.mailRules.isEmpty)
        #expect(try await list(toolbox).isEmpty)
        await #expect(throws: MCPToolError.self) { try await toolbox.call("delete_rule", arguments: ["id": .string(id)]) }
    }

    @Test func moveRulesNeedAFolderThatExists() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let created = try object(try await toolbox.call("create_rule", arguments: [
            "field": .string("subject"), "contains": .string("digest"), "action": .string("move"), "target": .string("archive"),
        ]))
        let rule = try #require(created["rule"] as? [String: Any])
        #expect(rule["target"] as? String == "Archive")
        #expect(model.mailRules.first?.action == .move("Archive"))

        do {
            _ = try await toolbox.call("create_rule", arguments: [
                "field": .string("from"), "contains": .string("github"), "action": .string("move"), "target": .string("Updates"),
            ])
            Issue.record("An unknown folder should be refused.")
        } catch let error as MCPToolError {
            #expect(error.message.contains("No folder “Updates”"))
        }
        #expect(model.mailRules.count == 1)
    }

    @Test func badInputIsRefusedWithAClearMessage() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        func refusal(_ arguments: [String: MCPValue]) async -> String? {
            do { _ = try await toolbox.call("create_rule", arguments: arguments); return nil } catch { return error.localizedDescription }
        }
        #expect(await refusal(["field": .string("from"), "contains": .string("   "), "action": .string("archive")])?.contains("can't be empty") == true)
        #expect(await refusal(["field": .string("body"), "contains": .string("x"), "action": .string("archive")])?.contains("from, to or subject") == true)
        #expect(await refusal(["field": .string("from"), "contains": .string("x"), "action": .string("explode")])?.contains("“action” must be") == true)
        #expect(await refusal(["field": .string("from"), "contains": .string("x"), "action": .string("group"), "target": .string("Updates")])?.contains("No group “Updates”") == true)
        #expect(await refusal(["field": .string("from"), "contains": .string("x"), "action": .string("label")])?.contains("label of 1 to 40") == true)
        #expect(await refusal(["field": .string("from"), "contains": .string("x"), "action": .string("star"), "mailbox": .string("Nowhere")])?.contains("No mailbox “Nowhere”") == true)
        #expect(model.mailRules.isEmpty)
        await #expect(throws: MCPToolError.self) { try await toolbox.call("update_rule", arguments: ["id": .string("nope")]) }
    }

    @Test func previewShowsWhatARuleWouldMatch() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let preview = try object(try await toolbox.call("preview_rule", arguments: ["field": .string("from"), "contains": .string("kettle")]))
        let found = try #require(preview["conversations"] as? [[String: Any]])
        #expect(!found.isEmpty)
        #expect(preview["total"] as? Int == found.count)
        #expect(found.allSatisfy { ($0["from"] as? String ?? "").lowercased().contains("kettle") })
        // Previewing saves nothing.
        #expect(model.mailRules.isEmpty)

        let none = try object(try await toolbox.call("preview_rule", arguments: ["field": .string("subject"), "contains": .string("zzz-no-such-subject")]))
        #expect(none["total"] as? Int == 0)
    }

    @Test func rulesForHiddenMailboxesStayHidden() async throws {
        let model = await model()
        let work = try #require(model.accounts.first { $0.label == "Work" })
        model.mailRules = [MailRule(field: .from, contains: "boss", action: .star, accountID: work.id)]
        var settings = model.connectionSettings
        settings.hiddenAccounts = [work.id]
        model.connectionSettings = settings
        let toolbox = MailToolbox(model: model)
        #expect(try await list(toolbox).isEmpty)
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("delete_rule", arguments: ["id": .string(model.mailRules[0].id.uuidString)])
        }
        #expect(model.mailRules.count == 1)
    }

    @Test func undoLastPutsRulesBack() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        _ = try await toolbox.call("create_rule", arguments: ["field": .string("from"), "contains": .string("weekly"), "action": .string("archive")])
        #expect(model.mailRules.count == 1)
        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(model.mailRules.isEmpty)
    }

    @Test func rulesWorkOverTheMCPProtocol() async throws {
        let model = await model()
        let server = MCPServer(toolbox: MailToolbox(model: model), name: "Margin", version: "test")
        func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
            let reply = try #require(await server.handle(body))
            return try #require((try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["result"] as? [String: Any])
        }
        let listed = try await send("tools/list", [:])
        let names = (listed["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names.contains("create_rule"))

        let created = try await send("tools/call", ["name": "create_rule", "arguments": ["field": "subject", "contains": "invoice", "action": "group", "target": "Bills to Pay"]])
        #expect(created["isError"] as? Bool == false)
        #expect(model.mailRules.first?.action == .label("Bills to Pay"))

        let refused = try await send("tools/call", ["name": "create_rule", "arguments": ["field": "subject", "contains": "", "action": "archive"]])
        #expect(refused["isError"] as? Bool == true)
        #expect(model.mailRules.count == 1)
    }

    @Test func activityHasPlainLabels() {
        for tool in ["list_rules", "preview_rule", "create_rule", "update_rule", "delete_rule"] {
            #expect(ConnectionsSettingsView.describe(tool) != tool)
        }
    }
}
