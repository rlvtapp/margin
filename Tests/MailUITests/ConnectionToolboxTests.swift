import Foundation
import MailCore
import Testing
@testable import MailUI

@MainActor @Suite struct ConnectionToolboxTests {
    func model() async -> MailModel {
        let model = MailModel(environment: .preview())
        await model.reload()
        return model
    }

    @Test func readingIsOnChangingNeedsPermission() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let names = await toolbox.tools().map(\.name)
        #expect(Array(names.prefix(7)) == ["list_mailboxes", "search_mail", "list_folders", "read_conversation", "create_draft", "list_labels", "get_selection"])
        #expect(!names.contains("archive") && !names.contains("send_email"))
        await #expect(throws: MCPToolError.self) { try await toolbox.call("archive", arguments: ["ids": .array([.string("x")])]) }

        var settings = model.connectionSettings
        settings.allowChanges = true
        model.connectionSettings = settings
        #expect(await toolbox.tools().map(\.name).contains("archive"))
        #expect(!(await toolbox.tools().map(\.name).contains("send_email")))
    }

    @Test func searchAndReadReturnMail() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let found = try await toolbox.call("search_mail", arguments: ["query": .string("lisbon")])
        let results = try #require((try JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any])?["conversations"] as? [[String: Any]])
        let id = try #require(results.first?["id"] as? String)
        #expect(results.first?["mailbox"] as? String == "Personal")

        let read = try await toolbox.call("read_conversation", arguments: ["id": .string(id)])
        #expect(read.contains("tile museum"))

        let sent = try await toolbox.call("search_mail", arguments: ["folder": .string("sent"), "mailbox": .string("Work")])
        #expect(sent.contains("Hiring plan draft"))
        #expect(!sent.contains("Flat keys"))

        _ = try await toolbox.call("create_draft", arguments: ["reply_to_id": .string(id), "body": .string("Count me in")])
        #expect(model.compose?.draft.text == "Count me in")
        #expect(model.compose?.draft.subject == "Re: Lisbon in May?")
    }

    func allowingChanges(_ model: MailModel) {
        var settings = model.connectionSettings
        settings.allowChanges = true
        model.connectionSettings = settings
    }

    func ids(_ toolbox: MailToolbox, _ query: String) async throws -> [String] {
        let found = try await toolbox.call("search_mail", arguments: ["query": .string(query)])
        let results = try #require((try JSONSerialization.jsonObject(with: Data(found.utf8)) as? [String: Any])?["conversations"] as? [[String: Any]])
        return results.compactMap { $0["id"] as? String }
    }

    @Test func agentsLabelManyConversationsAndTheLabelsShowInMargin() async throws {
        let model = await model()
        allowingChanges(model)
        let toolbox = MailToolbox(model: model)
        let found = try await ids(toolbox, "")
        try #require(found.count >= 2)
        let two = Array(found.prefix(2))

        let added = try await toolbox.call("add_label", arguments: ["ids": .array(two.map { .string($0) }), "label": .string("Trips")])
        #expect(added.contains("2 conversations"))
        let threads = model.inboxThreads(nil).filter { two.contains($0.id) }
        #expect(threads.allSatisfy { model.labels(for: $0).contains("Trips") })

        // A different spelling lands on the existing label.
        _ = try await toolbox.call("add_label", arguments: ["ids": .array([.string(two[0])]), "label": .string("trips")])
        #expect(model.labels(for: threads[0]).filter { $0.lowercased() == "trips" }.count == 1)

        let listed = try await toolbox.call("list_labels", arguments: [:])
        #expect(listed.contains("Trips"))

        _ = try await toolbox.call("rename_label", arguments: ["label": .string("Trips"), "new_name": .string("Travel")])
        #expect(threads.allSatisfy { model.labels(for: $0) == ["Travel"] || model.labels(for: $0).contains("Travel") })
        #expect(!model.allLabels.contains("Trips"))

        _ = try await toolbox.call("remove_label", arguments: ["ids": .array([.string(two[0])]), "label": .string("travel")])
        #expect(!model.labels(for: threads[0]).contains("Travel"))

        _ = try await toolbox.call("delete_label", arguments: ["label": .string("Travel")])
        #expect(!model.allLabels.contains("Travel"))
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("delete_label", arguments: ["label": .string("Travel")])
        }
    }

    @Test func changesNeedConversationIdsAndAllMustBeFound() async throws {
        let model = await model()
        allowingChanges(model)
        let toolbox = MailToolbox(model: model)
        let found = try await ids(toolbox, "")
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("add_label", arguments: ["id": .string(found[0]), "label": .string("x")])
        }
        await #expect(throws: MCPToolError.self) {
            try await toolbox.call("add_label", arguments: ["ids": .array([.string(found[0]), .string("missing")]), "label": .string("x")])
        }
    }

    @Test func selectionIsWhatThePersonHasOpen() async throws {
        let model = await model()
        let toolbox = MailToolbox(model: model)
        let found = try await ids(toolbox, "lisbon")
        model.selectedThreadID = found.first
        let selected = try await toolbox.call("get_selection", arguments: [:])
        let results = try #require(try JSONSerialization.jsonObject(with: Data(selected.utf8)) as? [[String: Any]])
        #expect(results.map { $0["id"] as? String } == [found.first])
    }

    @Test func snoozeAndBringBack() async throws {
        let model = await model()
        allowingChanges(model)
        let toolbox = MailToolbox(model: model)
        let id = try #require(try await ids(toolbox, "lisbon").first)
        let thread = try #require(model.inboxThreads(nil).first { $0.id == id })
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        _ = try await toolbox.call("snooze", arguments: ["ids": .array([.string(id)]), "until": .string(later)])
        #expect(model.snoozes[LabelStore.key(for: thread)] != nil)
        _ = try await toolbox.call("unsnooze", arguments: ["ids": .array([.string(id)])])
        #expect(model.snoozes[LabelStore.key(for: thread)] == nil)
    }
}
