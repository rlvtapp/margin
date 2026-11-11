import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

extension OnDeviceModel {
    /// Apple's on-device model with Margin's tools, when this device has it.
    static func makeAgent() -> (any MailAgentModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), isAvailable { return AppleAgent() }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// The on-device model runs the tool loop itself: each of Margin's tools becomes a `Tool` whose
/// arguments are described by the same JSON Schema, converted to a generation schema. The
/// context window is small, so the app gives it fewer tools and results are kept short.
@available(macOS 26, iOS 26, *)
struct AppleAgent: MailAgentModel {
    var attribution: String { AppleModel().attribution }
    var isCompact: Bool { true }
    var resultBudget: Int { 3_000 }

    func checkActions() async throws -> Bool { true }

    func run(instructions: String, request: String, tools: [MCPTool], maxSteps: Int,
             perform: @escaping AgentToolRunner) async throws -> AgentOutcome {
        let counter = CallCounter(limit: max(maxSteps, 1))
        let budget = resultBudget
        let wrapped: [any Tool] = try tools.map { tool in
            try MarginTool(tool: tool, parameters: try Self.generationSchema(for: tool)) { call in
                guard await counter.take() else { throw AgentLimitReached() }
                var result = await perform(call)
                result.text = AgentLoop.trimmed(result.text, to: budget)
                return result.isError ? "Error: \(result.text)" : result.text
            }
        }
        let session = LanguageModelSession(tools: wrapped, instructions: instructions)
        do {
            let text = try await AppleModel().plainErrors { try await session.respond(to: request).content }
            return AgentOutcome(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: await counter.used, reachedLimit: false)
        } catch let error as AssistantError {
            throw error
        } catch let error as LanguageModelSession.ToolCallError {
            if error.underlyingError is AgentLimitReached {
                return AgentOutcome(text: "", toolCalls: await counter.used, reachedLimit: true)
            }
            throw error.underlyingError
        }
    }

    /// A JSON Schema object (as Margin's tools write them) as a generation schema.
    static func generationSchema(for tool: MCPTool) throws -> GenerationSchema {
        try GenerationSchema(root: dynamic(AgentLoop.schema(tool), name: tool.name, description: nil), dependencies: [])
    }

    static func dynamic(_ schema: [String: Any], name: String, description: String?) -> DynamicGenerationSchema {
        let description = description ?? schema["description"] as? String
        if let choices = schema["enum"] as? [String] {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        switch schema["type"] as? String {
        case "object":
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            return DynamicGenerationSchema(name: name, description: description, properties: properties.keys.sorted().map { key in
                let property = properties[key] as? [String: Any] ?? [:]
                return DynamicGenerationSchema.Property(
                    name: key, description: property["description"] as? String,
                    schema: dynamic(property, name: "\(name)_\(key)", description: nil), isOptional: !required.contains(key)
                )
            })
        case "array":
            let items = schema["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: dynamic(items, name: "\(name)_item", description: nil),
                                           minimumElements: schema["minItems"] as? Int, maximumElements: schema["maxItems"] as? Int)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}

/// One of Margin's tools, as the on-device model sees it.
@available(macOS 26, iOS 26, *)
struct MarginTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let handler: @Sendable (AgentToolCall) async throws -> String

    init(tool: MCPTool, parameters: GenerationSchema, handler: @escaping @Sendable (AgentToolCall) async throws -> String) {
        name = tool.name
        description = tool.description
        self.parameters = parameters
        self.handler = handler
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let parsed = AgentLoop.arguments(fromJSON: arguments.jsonString) ?? [:]
        return try await handler(AgentToolCall(id: UUID().uuidString, name: name, arguments: parsed))
    }
}

/// Counts tool calls across the session, so a run stops at its step limit.
actor CallCounter {
    let limit: Int
    private(set) var used = 0

    init(limit: Int) { self.limit = limit }

    func take() -> Bool {
        guard used < limit else { return false }
        used += 1
        return true
    }
}

struct AgentLimitReached: Error {}
#endif
