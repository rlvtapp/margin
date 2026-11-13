#if os(macOS)
import Foundation
import Testing
@testable import MailCore

/// Claude Code and Codex as the assistant, with a stand-in script where the real tool would be,
/// so the tests don't need either installed (or a subscription).
@Suite struct CommandLineModelTests {
    /// A fake tool: records its arguments and what it was given, then prints `answer`.
    func fakeTool(answer: String, status: Int32 = 0, errors: String = "") throws -> (tool: URL, log: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appending(path: "log.txt")
        let script = folder.appending(path: "claude")
        let answerFile = folder.appending(path: "answer.txt")
        try Data(answer.utf8).write(to: answerFile)
        try """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "ARG:$a" >> "\(log.path)"; done
        printf 'PWD:%s\\n' "$PWD" >> "\(log.path)"
        printf 'STDIN:%s\\n' "$(cat)" >> "\(log.path)"
        printf '%s' "\(errors)" >&2
        cat "\(answerFile.path)"
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }

    @Test func claudeCodeAnswersInTheSameShapesAsTheOtherModels() async throws {
        let fake = try fakeTool(answer: #"Here it is: {"headline":"Trip booked","points":["May 14"],"action":""}"#)
        let model = CommandLineModel(tool: .claude, executable: fake.tool.path, model: "sonnet")
        let summary = try await model.summary(ModelRequest(task: .summary, instructions: "Summarize.", prompt: "The conversation"))
        #expect(summary.headline == "Trip booked" && summary.points == ["May 14"])

        let log = try String(contentsOf: fake.log, encoding: .utf8)
        // Print mode, no tools, nothing saved, the chosen model, the schema in the system prompt,
        // the mail on standard input, run in an empty folder (no project's instructions).
        #expect(log.contains("ARG:-p") && log.contains("ARG:--no-session-persistence") && log.contains("ARG:--strict-mcp-config"))
        #expect(log.contains("ARG:--tools\nARG:\n"))
        #expect(log.contains("ARG:--model\nARG:sonnet"))
        #expect(log.contains("JSON Schema") && log.contains("headline"))
        #expect(log.contains("STDIN:The conversation"))
        #expect(log.contains("PWD:") && log.contains("Margin Assistant"))
    }

    @Test func claudeCodeStreamsWhatItWrites() async throws {
        let events = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"{\"body\":\"Thanks, "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"see you Friday.\"}"}}}"#,
            #"{"type":"result","is_error":false,"result":"{\"body\":\"Thanks, see you Friday.\"}"}"#,
        ].joined(separator: "\n")
        let fake = try fakeTool(answer: events)
        let model = CommandLineModel(tool: .claude, executable: fake.tool.path, model: "haiku")
        let seen = Seen()
        let draft = try await model.reply(ModelRequest(task: .reply, instructions: "Write.", prompt: "x")) { await seen.add($0) }
        #expect(draft == "Thanks, see you Friday.")
        #expect(await seen.all == ["Thanks, ", "Thanks, see you Friday."])
        let log = try String(contentsOf: fake.log, encoding: .utf8)
        #expect(log.contains("ARG:stream-json") && log.contains("ARG:--include-partial-messages"))
    }

    @Test func aStreamedFailureSaysWhy() async throws {
        let fake = try fakeTool(answer: #"{"type":"result","is_error":true,"result":"You've reached your Haiku limit."}"#)
        let model = CommandLineModel(tool: .claude, executable: fake.tool.path, model: "haiku")
        await #expect(throws: AssistantError.self) {
            _ = try await model.answer(ModelRequest(task: .answer, instructions: "x", prompt: "y")) { _ in }
        }
    }

    actor Seen {
        var all: [String] = []
        func add(_ text: String) { all.append(text) }
    }

    @Test func itsOwnMessageComesBackWhenItFails() async throws {
        let fake = try fakeTool(answer: "", status: 1, errors: "You've reached your usage limit.")
        let model = CommandLineModel(tool: .claude, executable: fake.tool.path, model: "")
        do {
            _ = try await model.reply(ModelRequest(task: .reply, instructions: "Write.", prompt: "x"))
            Issue.record("A failing tool should throw.")
        } catch {
            #expect(error.localizedDescription.contains("usage limit"))
        }
        let log = try String(contentsOf: fake.log, encoding: .utf8)
        #expect(!log.contains("ARG:--model"))   // no model named: the tool's own default
    }

    @Test func rulesAreReadFromTheToolsOwnJSON() async throws {
        let fake = try fakeTool(answer: #"{"field":"from","contains":"@bank.example","action":"star","target":"","mailbox":"all"}"#)
        let model = CommandLineModel(tool: .claude, executable: fake.tool.path, model: "haiku")
        let parts = try await MailIntelligence(model: model).writeRule("star my bank", context: RuleContext(mailboxes: [], folders: [:], labels: [], groups: [], people: []))
        #expect(parts.action == "star" && parts.contains == "@bank.example")
    }

    /// The real Claude Code with the real sign-in: MARGIN_LIVE_CLAUDE=1 swift test --filter liveClaudeCode
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MARGIN_LIVE_CLAUDE"] == "1"))
    func liveClaudeCode() async throws {
        let path = try #require(CommandLineTool.claude.locate(refresh: true))
        let model = CommandLineModel(tool: .claude, executable: path, model: "haiku")
        let summary = try await model.summary(ModelRequest(task: .summary, instructions: "You summarize email conversations.",
            prompt: "From: Noor\nSubject: Lisbon in May?\n\nFlights are cheap. Shall we book the 14th to the 17th? Let me know by Friday."))
        #expect(!summary.headline.isEmpty)
        print("LIVE:", summary.headline, summary.points, summary.action ?? "")
        let fast = CommandLineModel(tool: .claude, executable: path, model: "haiku")
        let seen = Seen()
        let started = Date()
        let draft = try await fast.reply(ModelRequest(task: .reply, instructions: "Write a short, friendly email reply. About 60 words.",
                                                      prompt: "Noor asks: shall we book Lisbon for May 14 to 17?")) { await seen.add($0) }
        print("LIVE STREAM:", await seen.all.count, "updates in", Date().timeIntervalSince(started), "s:", draft)
        #expect(await seen.all.count > 1)
    }

    @Test func chatGPTsModelsComeFromCodexsOwnList() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"""
        {"models":[
          {"slug":"big","display_name":"Big","description":"Frontier intelligence for the most demanding work.","visibility":"list","priority":2},
          {"slug":"work","display_name":"Work","description":"Latest workhorse model.","visibility":"list","priority":1},
          {"slug":"hidden","display_name":"Hidden","description":"Fast and affordable agentic coding model.","visibility":"hide","priority":3},
          {"slug":"small","display_name":"Small","description":"Fast and affordable model for easier tasks.","visibility":"list","priority":4}]}
        """#.utf8).write(to: home.appending(path: ".codex/models_cache.json"))
        let models = CommandLineTool.codex.models(home: home.path)
        #expect(models.map(\.id) == ["work", "big", "small"])        // in its own order, hidden ones left out
        #expect(models.first?.name == "Work")
        #expect(CommandLineTool.codex.fastestModel(home: home.path) == "small")
        #expect(CommandLineTool.claude.models().map(\.id) == ["haiku", "sonnet", "opus"])
    }

    @Test func theToolsAreLookedForWhereTheyInstallThemselves() {
        let claude = CommandLineTool.claude.candidates(home: "/Users/x")
        #expect(claude.contains("/Users/x/.local/bin/claude") && claude.contains("/opt/homebrew/bin/claude") && claude.contains("/Users/x/.claude/local/claude"))
        #expect(CommandLineTool.codex.candidates(home: "/Users/x").contains("/opt/homebrew/bin/codex"))
        #expect(AssistantProvider.claudeCode.usesCommandLine && AssistantProvider.claudeCode.actionSupport == .no)
        #expect(AssistantSettings(provider: .claudeCode).model == "haiku")   // the fastest, for mail
        #expect(AssistantSettings(provider: .claude).model == "claude-haiku-5-5")
        #expect(CommandLineTool.codex.candidates(home: "/Users/x").first == "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        #expect(AssistantProvider.codex.title == "ChatGPT (your subscription)" && AssistantProvider.codex.name == "ChatGPT")
    }
}
#endif
