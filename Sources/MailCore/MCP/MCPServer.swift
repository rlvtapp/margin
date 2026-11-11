import Foundation

/// A tool an AI app can call.
public struct MCPTool: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema of the arguments, as JSON text.
    public var inputSchema: String

    public init(name: String, description: String, inputSchema: String) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// What the server exposes. The app implements it on top of its mail model.
public protocol MCPToolbox: Sendable {
    func tools() async -> [MCPTool]
    /// Runs a tool and returns its result as text (usually JSON). Throwing reports an error
    /// to the calling app without breaking the connection.
    func call(_ name: String, arguments: [String: MCPValue]) async throws -> String
    /// Like `call`, for tools that can answer with pictures too. Defaults to `call`'s text.
    func content(_ name: String, arguments: [String: MCPValue]) async throws -> [MCPContent]
}

/// One piece of a tool's answer.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(Data, mimeType: String)

    var json: [String: Any] {
        switch self {
        case .text(let text): ["type": "text", "text": text]
        case .image(let data, let mimeType): ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
        }
    }
}

extension MCPToolbox {
    public func content(_ name: String, arguments: [String: MCPValue]) async throws -> [MCPContent] {
        [.text(try await call(name, arguments: arguments))]
    }
}

/// JSON values in tool arguments, typed so they can cross actors.
public enum MCPValue: Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([MCPValue]), object([String: MCPValue])

    init(_ any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [Any]: self = .array(value.map(MCPValue.init))
        case let value as [String: Any]: self = .object(value.mapValues(MCPValue.init))
        default: self = .null
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}

public struct MCPToolError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The Model Context Protocol over JSON-RPC 2.0, independent of transport: give it one
/// message, get the reply (or nil for notifications).
public actor MCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let toolbox: any MCPToolbox
    let name: String
    let version: String
    /// Called for every tool call, for the activity list in Settings.
    let onCall: @Sendable (String) -> Void

    public init(toolbox: any MCPToolbox, name: String, version: String, onCall: @escaping @Sendable (String) -> Void = { _ in }) {
        self.toolbox = toolbox
        self.name = name
        self.version = version
        self.onCall = onCall
    }

    public func handle(_ body: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Self.error(id: nil, code: -32700, message: "Parse error")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : Self.error(id: id, code: -32600, message: "Invalid request")
        }
        // Notifications (no id) get no reply.
        guard id != nil else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return Self.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": name, "version": self.version],
                "instructions": "Margin is the person's mail app. Use search_mail to find conversations and read_conversation to read them. For what needs the person now (\"what should I deal with?\"), call list_needs_you. To address mail by name, call find_people. To sort the inbox, call list_groups, then repeat list_to_sort and sort_into_group (skip_sorting when nothing fits) until nothing is left; use Home's groups, not labels. To draft, call get_writing_style, then save_draft. For a standing request about new mail (\"always move mail from X to Y\"), make a rule: check the target with list_groups, list_folders or list_labels, call preview_rule, then create_rule (list_rules, update_rule and delete_rule manage them); rules only act on new mail, so handle what's already in the inbox with the usual tools if asked. Only send mail when the person clearly asked you to.",
            ])
        case "ping":
            return Self.result(id: id, [:])
        // Margin offers tools only, but some apps (Codex) ask for these on every start; empty
        // lists keep them happy instead of logging "method not found".
        case "resources/list":
            return Self.result(id: id, ["resources": []])
        case "resources/templates/list":
            return Self.result(id: id, ["resourceTemplates": []])
        case "prompts/list":
            return Self.result(id: id, ["prompts": []])
        case "tools/list":
            let tools = await toolbox.tools().map { tool -> [String: Any] in
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? ["type": "object"]
                return ["name": tool.name, "description": tool.description, "inputSchema": schema]
            }
            return Self.result(id: id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = (params["arguments"] as? [String: Any] ?? [:]).mapValues(MCPValue.init)
            onCall(name)
            do {
                let parts = try await toolbox.content(name, arguments: arguments)
                return Self.result(id: id, ["content": parts.map(\.json), "isError": false])
            } catch {
                return Self.result(id: id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func result(id: Any?, _ result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result], options: [.sortedKeys])
    }

    static func error(id: Any?, code: Int, message: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]], options: [.sortedKeys])
    }
}
