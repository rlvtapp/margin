import Foundation

/// A model to pick: its id, the name people know it by, and what it's good at.
public struct ModelChoice: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String

    public init(id: String, name: String, detail: String = "") {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// Claude Code and Codex, the coding tools people already have on their Mac, used as the
/// assistant: Margin runs the tool for each request, so it answers with the person's own
/// subscription and their sign-in stays with the tool. Mac only: iPhone and iPad can't run
/// other programs. Each request starts the tool afresh, so it takes a few seconds.
public enum CommandLineTool: String, CaseIterable, Sendable {
    case claude, codex

    var executableName: String { rawValue }

    /// Places the tools install themselves, then the person's shell, which knows the rest.
    func candidates(home: String = NSHomeDirectory()) -> [String] {
        let name = executableName
        var paths = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                     "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)", "\(home)/.volta/bin/\(name)"]
        if self == .claude { paths.insert("\(home)/.claude/local/claude", at: 1) }
        if self == .codex {
            // The ChatGPT app carries Codex inside it, signed in with the same account.
            paths.insert(contentsOf: ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                                      "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                                      "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"], at: 0)
            paths.append("\(home)/.cargo/bin/codex")
        }
        return paths
    }

    /// Model names Claude Code takes, newest of each; Codex's come from `models()`.
    public var modelChoices: [String] { models().map(\.id) }

    /// The models to pick from, quickest and cheapest first for Claude Code; for Codex the ones
    /// the ChatGPT app lists (from the list Codex keeps, `~/.codex/models_cache.json`).
    public func models(home: String = NSHomeDirectory()) -> [ModelChoice] {
        switch self {
        case .claude:
            return [ModelChoice(id: "haiku", name: "Haiku", detail: String(localized: "Fastest and cheapest")),
                    ModelChoice(id: "sonnet", name: "Sonnet", detail: String(localized: "Balanced")),
                    ModelChoice(id: "opus", name: "Opus", detail: String(localized: "Most capable, slowest"))]
        case .codex:
            let url = URL(fileURLWithPath: home).appending(path: ".codex/models_cache.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = object["models"] as? [[String: Any]] else { return [] }
            return list
                .filter { ($0["visibility"] as? String ?? "list") == "list" }
                .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
                .compactMap { model in
                    guard let id = model["slug"] as? String else { return nil }
                    return ModelChoice(id: id, name: model["display_name"] as? String ?? id, detail: model["description"] as? String ?? "")
                }
        }
    }

    /// The quickest, cheapest model Codex offers (its description says "fast" and
    /// "affordable" or "cheap"), for mail; nil to leave it to Codex.
    public func fastestModel(home: String = NSHomeDirectory()) -> String? {
        switch self {
        case .claude: return "haiku"
        case .codex:
            return models(home: home).first { choice in
                let text = choice.detail.lowercased()
                return text.contains("fast") && (text.contains("affordable") || text.contains("cheap")) && !text.contains("coding")
            }?.id
        }
    }

    #if os(macOS)
    private static let found = FoundPaths()

    /// Where the tool is on this Mac, or nil when it isn't installed. Remembered, so starting
    /// Margin never waits on it; `refresh` looks again (after installing one, say).
    public func locate(refresh: Bool = false) -> String? {
        if !refresh, let known = Self.found.get(self) { return known }
        let path = search()
        Self.found.set(self, path)
        return path
    }

    private final class FoundPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [CommandLineTool: String?] = [:]
        func get(_ tool: CommandLineTool) -> String?? { lock.withLock { paths[tool] } }
        func set(_ tool: CommandLineTool, _ path: String?) { lock.withLock { paths[tool] = .some(path) } }
    }

    private func search() -> String? {
        let manager = FileManager.default
        if let found = candidates().first(where: { manager.isExecutableFile(atPath: $0) }) { return found }
        guard let output = try? CommandLineRunner.run(executable: "/bin/zsh", arguments: ["-lc", "command -v \(executableName)"],
                                                       input: nil, timeout: 5).output else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && manager.isExecutableFile(atPath: path) ? path : nil
    }
    #endif
}

#if os(macOS)
/// Runs a program and gives back what it wrote, with a time limit.
enum CommandLineRunner {
    struct Result { var output: String; var errors: String; var status: Int32 }

    /// The usual places programs live, ahead of what a Mac app is given: tools started from
    /// Terminal find their helpers (node, git) there.
    static var searchPath: String {
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (extra + current).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// What the tools run with: the usual places for their helpers, and nothing they'd do on
    /// their own beside the answer (update checks, telemetry), which took most of their start.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["NO_COLOR"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    /// Runs a program and hands over each line it writes as it comes, for answers shown while
    /// they're written. Ends with what went wrong, in the program's words, when it fails.
    static func lines(executable: String, arguments: [String], input: String?, timeout: TimeInterval,
                      directory: URL? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            if let directory { process.currentDirectoryURL = directory }
            let output = Pipe(), errors = Pipe(), inputPipe = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = inputPipe
            let buffer = LineBuffer()
            let collected = Collected()
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                collected.add(out: data)
                for line in buffer.add(data) { continuation.yield(line) }
            }
            errors.fileHandleForReading.readabilityHandler = { collected.add(err: $0.availableData) }
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                let rest = output.fileHandleForReading.readDataToEndOfFile()
                collected.add(out: rest)
                for line in buffer.add(rest) + buffer.flush() { continuation.yield(line) }
                collected.add(err: errors.fileHandleForReading.readDataToEndOfFile())
                if finished.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: AssistantError.badResponse(String(
                        ([collected.err, collected.out].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                         ?? String(localized: "It stopped without an answer.")).suffix(300))))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            if let input { inputPipe.fileHandleForWriting.write(Data(input.utf8)) }
            try? inputPipe.fileHandleForWriting.close()
            nonisolated(unsafe) let running = process
            nonisolated(unsafe) let timer = DispatchWorkItem { if running.isRunning { running.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            continuation.onTermination = { _ in
                timer.cancel()
                if running.isRunning { running.terminate() }
            }
        }
    }

    /// Splits what arrives into whole lines.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        func add(_ data: Data) -> [String] {
            lock.withLock {
                pending.append(data)
                var lines: [String] = []
                while let end = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...end)
                }
                return lines
            }
        }
        func flush() -> [String] {
            lock.withLock {
                defer { pending = Data() }
                return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
            }
        }
    }

    static func run(executable: String, arguments: [String], input: String?, timeout: TimeInterval,
                    directory: URL? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe(), errors = Pipe(), inputPipe = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = inputPipe
        // Read both pipes while it runs, so a long answer can't fill one and stall the tool.
        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { collected.add(out: $0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { collected.add(err: $0.availableData) }
        try process.run()
        if let input { inputPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw AssistantError.badResponse(String(localized: "It took too long to answer."))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        collected.add(out: output.fileHandleForReading.readDataToEndOfFile())
        collected.add(err: errors.fileHandleForReading.readDataToEndOfFile())
        return Result(output: collected.out, errors: collected.err, status: process.terminationStatus)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data(), errData = Data()
        func add(out data: Data) { lock.withLock { outData.append(data) } }
        func add(err data: Data) { lock.withLock { errData.append(data) } }
        var out: String { lock.withLock { String(decoding: outData, as: UTF8.self) } }
        var err: String { lock.withLock { String(decoding: errData, as: UTF8.self) } }
    }
}

/// The assistant answered by Claude Code or Codex. Every answer is asked for as JSON in the
/// same shapes the hosted models use, then read with the same decoders.
public struct CommandLineModel: MailLanguageModel {
    public let tool: CommandLineTool
    public let executable: String
    /// A model the tool knows ("sonnet", "opus", "haiku" for Claude Code); empty for its default.
    public let model: String

    public init(tool: CommandLineTool, executable: String, model: String) {
        self.tool = tool
        self.executable = executable
        self.model = model
    }

    public var attribution: String {
        switch tool {
        case .claude: String(localized: "by Claude Code", comment: "Who wrote an assistant answer")
        case .codex: String(localized: "by ChatGPT", comment: "Who wrote an assistant answer")
        }
    }

    /// Less than the hosted models get: the tool reads every word before it starts answering,
    /// and mail rarely needs more.
    public var transcriptBudget: Int { 24_000 }

    public func summary(_ request: ModelRequest) async throws -> ThreadSummary { try AnswerSchema.decodeSummary(try await json(request)) }
    public func labels(_ request: ModelRequest) async throws -> [String] { try AnswerSchema.decodeLabels(try await json(request)) }
    public func reply(_ request: ModelRequest) async throws -> String { try AnswerSchema.decodeReply(try await json(request)) }
    public func answer(_ request: ModelRequest) async throws -> MailAnswer { try AnswerSchema.decodeAnswer(try await json(request)) }

    /// Claude Code's answer shown as it's written; Codex hands it over whole.
    public func answer(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> MailAnswer {
        try AnswerSchema.decodeAnswer(Data(try await streamed(request, key: "answer", partial: partial).utf8))
    }

    public func reply(_ request: ModelRequest, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        try AnswerSchema.decodeReply(Data(try await streamed(request, key: "body", partial: partial).utf8))
    }

    /// The JSON answer, with the text of `key` handed over as Claude Code writes it.
    private func streamed(_ request: ModelRequest, key: String, partial: @escaping @Sendable (String) async -> Void) async throws -> String {
        let (system, prompt) = try Self.asJSON(request)
        guard tool == .claude else { return try await run(system: system, prompt: prompt) }
        var reader = StreamedAnswer(partial: partial, key: key)
        var final: String?
        let arguments = Self.claudeArguments(system: system, model: model, streaming: true)
        for try await line in CommandLineRunner.lines(executable: executable, arguments: arguments, input: prompt,
                                                      timeout: 240, directory: Self.workFolder) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "stream_event":
                let inner = event["event"] as? [String: Any]
                let delta = inner?["delta"] as? [String: Any]
                if inner?["type"] as? String == "content_block_delta", delta?["type"] as? String == "text_delta",
                   let text = delta?["text"] as? String {
                    await reader.add(text)
                }
            case "result":
                if event["is_error"] as? Bool == true {
                    throw AssistantError.badResponse(String((event["result"] as? String ?? String(localized: "It stopped without an answer.")).suffix(300)))
                }
                final = event["result"] as? String
            default:
                break
            }
        }
        return final ?? reader.text
    }

    /// A rule's parts are their own JSON, asked for in the instructions.
    public func ruleParts(_ request: ModelRequest) async throws -> RuleParts {
        try RuleParts.parse(try await run(system: request.instructions, prompt: request.prompt))
    }

    /// The answer as JSON in the task's shape.
    private func json(_ request: ModelRequest) async throws -> Data {
        let (system, prompt) = try Self.asJSON(request)
        return Data(try await run(system: system, prompt: prompt).utf8)
    }

    /// The request with the task's JSON shape spelled out in the instructions.
    static func asJSON(_ request: ModelRequest) throws -> (system: String, prompt: String) {
        let schema = AnswerSchema.schema(for: request.task)
        let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
        return (request.instructions + "\n\nAnswer with one JSON object that matches this JSON Schema and nothing else:\n" + schemaText,
                request.prompt)
    }

    /// An empty folder to run in, so no project's instructions are picked up.
    static var workFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Margin Assistant", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Print mode with nothing extra: no tools, no connectors or MCP servers (they took most of
    /// its start), nothing saved.
    static func claudeArguments(system: String, model: String, streaming: Bool) -> [String] {
        var arguments = ["-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--system-prompt", system]
        arguments += streaming ? ["--output-format", "stream-json", "--include-partial-messages", "--verbose"] : ["--output-format", "text"]
        if !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    /// Runs the tool once, with no tools of its own and nothing saved, in an empty folder so
    /// it picks up no project's instructions.
    func run(system: String, prompt: String) async throws -> String {
        let tool = tool, executable = executable, model = model
        return try await Task.detached(priority: .userInitiated) {
            let folder = Self.workFolder
            switch tool {
            case .claude:
                let arguments = Self.claudeArguments(system: system, model: model, streaming: false)
                let result = try CommandLineRunner.run(executable: executable, arguments: arguments, input: prompt, timeout: 240, directory: folder)
                return try Self.answer(result)
            case .codex:
                let last = folder.appending(path: "codex-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: last) }
                // Nothing saved, nothing run, a quick answer, and none of the tool servers in its
                // settings (one of which can be Margin itself).
                var arguments = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only",
                                 "-c", "model_reasoning_effort=low", "-c", "mcp_servers={}", "--output-last-message", last.path]
                if !model.isEmpty { arguments += ["--model", model] }
                arguments.append(system + "\n\n---\n\n" + prompt)
                let result = try CommandLineRunner.run(executable: executable, arguments: arguments, input: nil, timeout: 240, directory: folder)
                if let text = try? String(contentsOf: last, encoding: .utf8), !text.isEmpty { return text }
                return try Self.answer(result)
            }
        }.value
    }

    /// What the tool answered, or what went wrong in its own words (a usage limit, a sign-in).
    static func answer(_ result: CommandLineRunner.Result) throws -> String {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0, !text.isEmpty { return text }
        let problem = [result.errors, result.output].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? String(localized: "It stopped without an answer.")
        throw AssistantError.badResponse(String(problem.suffix(300)))
    }
}
#endif
