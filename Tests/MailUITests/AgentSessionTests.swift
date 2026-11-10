import Foundation
import MailCore
import Testing
@testable import MailUI

/// An AI app's session, start to finish, over Margin's real HTTP MCP server with the real tools.
@MainActor @Suite struct AgentSessionTests {
    @Test func anAgentSortsMailOverTheConnection() async throws {
        let model = MailModel(environment: .preview())
        await model.reload()
        var settings = model.connectionSettings
        settings.allowChanges = true
        model.connectionSettings = settings

        let port = UInt16.random(in: 50_000...60_000)
        let http = model.makeConnectionServer(port: port, token: "t0ken")
        try http.start()
        defer { http.stop() }
        try await Task.sleep(for: .milliseconds(200))

        var next = 0
        func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            next += 1
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("Bearer t0ken", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": next, "method": method, "params": params])
            let (data, _) = try await URLSession.shared.data(for: request)
            let reply = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(reply["result"] as? [String: Any], "\(reply)")
        }
        func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
            let result = try await rpc("tools/call", ["name": tool, "arguments": arguments])
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (text, result["isError"] as? Bool ?? false)
        }

        _ = try await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test-agent", "version": "1"]])
        let tools = try #require((try await rpc("tools/list"))["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        #expect(tools.contains("add_label") && tools.contains("undo_last") && !tools.contains("send_email"))

        // Find mail, label a batch, and the label is in Margin.
        let found = (try JSONSerialization.jsonObject(with: Data(try await call("search_mail", ["limit": 3]).text.utf8)) as? [String: Any])?["conversations"] as? [[String: Any]] ?? []
        let ids = found.compactMap { $0["id"] as? String }
        try #require(ids.count == 3)
        let labelled = try await call("add_label", ["ids": ids, "label": "Sorted by agent"])
        #expect(!labelled.isError && labelled.text.contains("3 conversations"))
        let threads = model.inboxThreads(nil).filter { ids.contains($0.id) }
        #expect(threads.count == 3 && threads.allSatisfy { model.labels(for: $0).contains("Sorted by agent") })

        // Mistakes come back as errors the agent can read, not failures.
        let wrong = try await call("add_label", ["ids": ["nope"], "label": "x"])
        #expect(wrong.isError && wrong.text.contains("search_mail"))

        // Undo its own change.
        _ = try await call("undo_last")
        #expect(threads.allSatisfy { !model.labels(for: $0).contains("Sorted by agent") })

        // Trash, then bring it back.
        let subject = try #require(threads.first?.subject)
        _ = try await call("trash", ["ids": [ids[0]]])
        #expect(!model.inboxThreads(nil).contains { $0.subject == subject })
        let back = try await call("undo_last")
        #expect(!back.isError, "\(back.text)")
        #expect(model.inboxThreads(nil).contains { $0.subject == subject })

        // The person sees what happened.
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.connectionActivity.contains { $0.tool == "trash" })
    }
}
