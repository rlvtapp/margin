import Foundation
import Testing
@testable import MailCore

struct EchoToolbox: MCPToolbox {
    func tools() async -> [MCPTool] {
        [MCPTool(name: "echo", description: "Echoes text.", inputSchema: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)]
    }

    func call(_ name: String, arguments: [String: MCPValue]) async throws -> String {
        guard name == "echo" else { throw MCPToolError("Unknown tool") }
        return arguments["text"]?.string ?? ""
    }
}

@Suite(.serialized) struct MCPTests {
    func send(_ server: MCPServer, _ json: String) async throws -> [String: Any]? {
        guard let data = await server.handle(Data(json.utf8)) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func speaksJSONRPC() async throws {
        let server = MCPServer(toolbox: EchoToolbox(), name: "Margin", version: "0.1.0")
        let initialize = try #require(try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "Margin")

        let old = try #require(try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect((old["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.supportedVersions[0])

        #expect(try await send(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try #require(try await send(server, #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "echo")
        #expect((tools.first?["inputSchema"] as? [String: Any])?["type"] as? String == "object")

        let call = try #require(try await send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#))
        let content = (call["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "hi")
        #expect(call["id"] as? Int == 3)

        let failed = try #require(try await send(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#))
        #expect((failed["result"] as? [String: Any])?["isError"] as? Bool == true)

        let unknown = try #require(try await send(server, #"{"jsonrpc":"2.0","id":5,"method":"completion/complete"}"#))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        // Asked by some apps on every start: answered with nothing rather than an error.
        let resources = try #require(try await send(server, #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#))
        #expect(((resources["result"] as? [String: Any])?["resources"] as? [Any])?.isEmpty == true)
        let garbage = try #require(try await send(server, "not json"))
        #expect((garbage["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func httpServerChecksTokenAndOrigin() async throws {
        let port = UInt16.random(in: 50_000...60_000)
        let http = MCPHTTPServer(port: port, token: "secret", server: MCPServer(toolbox: EchoToolbox(), name: "Margin", version: "0"))
        try http.start()
        defer { http.stop() }
        try await Task.sleep(for: .milliseconds(200))

        func post(_ body: String, headers: [String: String]) async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        #expect(try await post(ping, headers: [:]).0 == 401)
        #expect(try await post(ping, headers: ["Authorization": "Bearer wrong"]).0 == 401)
        #expect(try await post(ping, headers: ["Authorization": "Bearer secret", "Origin": "https://evil.example"]).0 == 403)
        let ok = try await post(ping, headers: ["Authorization": "Bearer secret", "Origin": "http://localhost:3000"])
        #expect(ok.0 == 200)
        #expect(ok.1.contains("\"result\""))
        #expect(try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, headers: ["Authorization": "Bearer secret"]).0 == 202)
    }

    @Test func tokensAreRandomAndURLSafe() {
        let a = MCPHTTPServer.makeToken(), b = MCPHTTPServer.makeToken()
        #expect(a != b)
        #expect(a.count >= 40)
        #expect(!a.contains("+") && !a.contains("/") && !a.contains("="))
    }
}
