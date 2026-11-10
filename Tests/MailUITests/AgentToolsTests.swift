import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct AgentToolsTests {
    func setUp(changes: Bool = true, sending: Bool = false, settings: Bool = false) async -> (MailModel, MailToolbox) {
        let model = MailModel(environment: .preview())
        await model.reload()
        var connection = model.connectionSettings
        connection.allowChanges = changes
        connection.allowSending = sending
        connection.allowSettings = settings
        model.connectionSettings = connection
        return (model, MailToolbox(model: model))
    }

    func ids(_ toolbox: MailToolbox, _ query: String) async throws -> [String] {
        let found = try await toolbox.call("search_mail", arguments: ["query": .string(query)])
        let results = try #require((try JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any])?["conversations"] as? [[String: Any]])
        return results.compactMap { $0["id"] as? String }
    }

    func list(_ text: String) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    @Test func eachSwitchOpensItsOwnTools() async {
        let (_, reading) = await setUp(changes: false)
        let names = await reading.tools().map(\.name)
        #expect(names.contains("list_outbox") && names.contains("open_in_margin") && names.contains("get_settings"))
        #expect(!names.contains("trash") && !names.contains("undo_last") && !names.contains("change_settings") && !names.contains("send_now"))

        let (_, all) = await setUp(changes: true, sending: true, settings: true)
        let every = await all.tools().map(\.name)
        for name in ["trash", "undo_last", "create_folder", "save_template", "change_settings", "set_signature", "send_now", "respond_to_invite"] {
            #expect(every.contains(name), "\(name)")
        }
        #expect(Set(every).count == every.count)
    }

    @Test func undoPutsLabelsAndStarsBack() async throws {
        let (model, toolbox) = await setUp()
        let id = try #require(try await ids(toolbox, "lisbon").first)
        let thread = try #require(model.inboxThreads(nil).first { $0.id == id })
        let wasStarred = thread.isStarred

        _ = try await toolbox.call("add_label", arguments: ["ids": .array([.string(id)]), "label": .string("Trips")])
        _ = try await toolbox.call("set_starred", arguments: ["ids": .array([.string(id)]), "starred": .bool(!wasStarred)])
        #expect(model.inboxThreads(nil).first { $0.id == id }?.isStarred == !wasStarred)

        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(model.inboxThreads(nil).first { $0.id == id }?.isStarred == wasStarred)
        #expect(model.labels(for: thread).contains("Trips"))
        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(!model.labels(for: thread).contains("Trips"))
        await #expect(throws: MCPToolError.self) { try await toolbox.call("undo_last", arguments: [:]) }
    }

    @Test func templatesStartDrafts() async throws {
        let (model, toolbox) = await setUp()
        _ = try await toolbox.call("save_template", arguments: ["name": .string("Agent thanks"), "subject": .string("Thank you"), "body": .string("Thanks so much, {first_name}!")])
        let template = try #require(try list(try await toolbox.call("list_templates", arguments: [:])).first { $0["name"] as? String == "Agent thanks" })
        let templateID = try #require(template["id"] as? String)

        _ = try await toolbox.call("create_draft", arguments: ["to": .string("Noor Haddad <noor@example.com>"), "template_id": .string(templateID)])
        #expect(model.compose?.draft.text.contains("Thanks so much") == true)

        _ = try await toolbox.call("update_template", arguments: ["id": .string(templateID), "name": .string("Thank you note")])
        #expect(model.templates.contains { $0.name == "Thank you note" })
        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(model.templates.contains { $0.name == "Agent thanks" })
    }

    @Test func draftsCarryAttachments() async throws {
        let (model, toolbox) = await setUp()
        let content = Data("Agenda: tiles, lunch".utf8).base64EncodedString()
        _ = try await toolbox.call("create_draft", arguments: [
            "to": .string("noor@example.com"), "body": .string("Here's the plan."),
            "attachments": .array([.object(["filename": .string("plan.txt"), "content_base64": .string(content), "mime_type": .string("text/plain")])]),
        ])
        #expect(model.compose?.draft.attachments.first?.filename == "plan.txt")
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("create_draft", arguments: ["attachments": .array([.object(["filename": .string("x")])])])
        }
    }

    @Test func outboxCanBeRescheduledCancelledAndBroughtBack() async throws {
        let (model, toolbox) = await setUp(sending: true)
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        _ = try await toolbox.call("send_email", arguments: ["to": .string("noor@example.com"), "subject": .string("Tomorrow"), "body": .string("See you"), "send_at": .string(later)])
        let item = try #require(try list(try await toolbox.call("list_outbox", arguments: [:])).first { $0["subject"] as? String == "Tomorrow" })
        let id = try #require(item["id"] as? String)

        let evenLater = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 86_400))
        _ = try await toolbox.call("reschedule", arguments: ["id": .string(id), "send_at": .string(evenLater)])
        #expect(model.outbox.first?.sendAt.timeIntervalSinceNow ?? 0 > 86_400 + 60)

        _ = try await toolbox.call("cancel_scheduled", arguments: ["id": .string(id)])
        #expect(model.outbox.isEmpty)
        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(model.outbox.count == 1)
    }

    @Test func settingsChangeAndUndo() async throws {
        let (model, toolbox) = await setUp(settings: true)
        let before = model.appearance
        let target: AppAppearance = before == .dark ? .light : .dark
        _ = try await toolbox.call("change_settings", arguments: ["appearance": .string(target.rawValue), "undo_send_seconds": .number(10)])
        #expect(model.appearance == target && model.undoSendDelay == 10)
        await #expect(throws: MCPToolError.self) { try await toolbox.call("change_settings", arguments: ["undo_send_seconds": .number(7)]) }
        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(model.appearance == before)
    }

    @Test func openInMarginShowsWhatWasAskedFor() async throws {
        let (model, toolbox) = await setUp(changes: false)
        _ = try await toolbox.call("open_in_margin", arguments: ["view": .string("starred")])
        #expect(model.place == .starred(account: nil))
        let id = try #require(try await ids(toolbox, "lisbon").first)
        _ = try await toolbox.call("open_in_margin", arguments: ["conversation_id": .string(id)])
        #expect(model.selectedThreadID == id)
        _ = try await toolbox.call("open_in_margin", arguments: ["search": .string("from:noor")])
        #expect(model.place == .search("from:noor"))
    }

    @Test func foldersWithMailAreNeverDeleted() async throws {
        let (model, toolbox) = await setUp()
        let account = try #require(model.visibleAccounts.first)
        guard let folder = model.ownFolders(of: account.id).first?.mailbox else { return }
        let inside = (try? await model.provider(for: account).threads(in: folder, limit: 1)) ?? []
        guard !inside.isEmpty else { return }
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("delete_folder", arguments: ["folder": .string(folder.name), "mailbox": .string(account.label)])
        }
    }

    @Test func trashCanBeUndone() async throws {
        let (model, toolbox) = await setUp()
        let id = try #require(try await ids(toolbox, "lisbon").first)
        let subject = try #require(model.inboxThreads(nil).first { $0.id == id }?.subject)
        _ = try await toolbox.call("trash", arguments: ["ids": .array([.string(id)])])
        #expect(!model.inboxThreads(nil).contains { $0.subject == subject })
        _ = try await toolbox.call("undo_last", arguments: [:])
        #expect(model.inboxThreads(nil).contains { $0.subject == subject })
    }
}
