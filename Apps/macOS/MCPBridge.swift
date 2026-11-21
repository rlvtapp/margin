import AppKit
import Foundation
import MailCore
import MailUI

/// `Margin --mcp`: what MCP apps launch (stdio transport). Reads JSON-RPC messages from stdin,
/// one per line, and writes the replies to stdout (logs go to stderr only, because stdout
/// belongs to the protocol).
///
/// - Margin open: each message goes to the running app's server on 127.0.0.1.
/// - Margin closed: it never opens Margin. It starts Margin's core as its own process
///   (`Margin --mcp` too, started with `MARGIN_MCP_CORE=1`), which reads what's on this Mac and can change events in their
///   calendars, and which exits by itself after a few quiet minutes, so its memory is gone.
/// - Nothing in between: no timers, no checks. This process only waits for the next message,
///   and for Margin's one signal that the AI settings changed (about 3 MB, no wakeups).
enum MCPBridge {
    /// With `-sample-mail`, the sample app's settings and token (SampleMode.swift).
    private static var defaults: UserDefaults { SampleMode.isOn ? SampleMode.defaults : .standard }

    /// The settings as they are now: read again for every message, so turning things on in
    /// Margin applies without restarting the AI app.
    private static var settings: ConnectionSettings {
        defaults.data(forKey: "connectionSettings")
            .flatMap { try? JSONDecoder().decode(ConnectionSettings.self, from: $0) } ?? ConnectionSettings()
    }

    // Neither the bridge nor the core touches NSApplication: making it registers the process
    // with macOS as a running copy of Margin (same bundle id), and then opening Margin from the
    // Dock or Finder fails while an AI app is connected ("Margin is not open", error -600).
    // Without it they're plain processes: no Dock icon, and Margin opens normally.

    static func run() -> Never {
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
        listenForSettingsChanges()
        Task { @MainActor in
            for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                await handle(line)
            }
            CoreProcess.shared.stop()
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Set on the core's process by the bridge, so both are just `Margin --mcp`.
    static let coreVariable = "MARGIN_MCP_CORE"
    static var isCore: Bool { ProcessInfo.processInfo.environment[coreVariable] == "1" }

    /// The core (`isCore`): Margin's core on its own, started by the bridge while Margin is
    /// closed. One answer line for each message line (`noReply` for notifications); it exits
    /// after `Core.quiet` without a message, or when the bridge goes.
    static func runCore() -> Never {
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
        Task { @MainActor in
            for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                write(await Core.shared.answer(Data(line.utf8)) ?? noReply)
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// What the core answers to a notification, so the bridge knows nothing is coming.
    nonisolated static let noReply = Data(#"{"margin":"no-reply"}"#.utf8)

    // MARK: One message

    /// Where the last answer came from, so the AI app is told its tools changed when it moves
    /// between the open app (all tools) and the core (reading and the calendar).
    @MainActor private static var answeredByCore: Bool?

    @MainActor private static func handle(_ line: String) async {
        let body = Data(line.utf8)
        let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"]
        let settings = settings
        guard settings.enabled else {
            reply(error: "Margin's connection is off. Turn on Settings → AI Apps → Let AI apps use Margin.", id: id)
            return
        }
        guard let token = token(), let url = URL(string: "http://127.0.0.1:\(settings.port)/mcp") else {
            reply(error: "Margin couldn't read its connection token from the Keychain.", id: id)
            return
        }
        switch await post(body, to: url, token: token) {
        case .success(let answer):
            switchSource(toCore: false)
            if let answer { write(answer) } // nil: a notification, nothing to send back
        case .closed:
            // Not open, and answering without Margin is turned off: open Margin instead.
            guard settings.answersWhileClosed else {
                CoreProcess.shared.stop()
                reply(error: String(localized: "Margin is closed. Open Margin, or turn on Settings → AI Apps → Answer while Margin is closed."), id: id)
                return
            }
            // Not open: Margin's core answers, started for this if it isn't running.
            switchSource(toCore: true)
            if let answer = await CoreProcess.shared.send(line) { write(answer) }
            else if id != nil { reply(error: "Margin's core couldn't start. Open Margin, then try again.", id: id) }
        case .failure(let message):
            reply(error: message, id: id)
        }
    }

    @MainActor private static func switchSource(toCore: Bool) {
        defer { answeredByCore = toCore }
        guard let before = answeredByCore, before != toCore else { return }
        notifyToolsChanged()
    }

    /// The shared token: made here when Margin hasn't made one yet; the app reads the same item.
    private static func token() -> String? {
        let keychain = Keychain(service: SampleMode.isOn ? SampleMode.service : Bundle.main.bundleIdentifier ?? "app.relevate.margin")
        if let token = keychain.read(key: "mcp.token") { return token }
        let token = MCPHTTPServer.makeToken()
        return (try? keychain.save(token, key: "mcp.token")) != nil ? token : nil
    }

    enum Outcome { case success(Data?), closed, failure(String) }

    private static func post(_ body: Data, to url: URL, token: String) async -> Outcome {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: return .success(data)
            case 202: return .success(nil)
            case 401: return .failure("Margin refused the connection token. Copy the setup again from Margin's settings.")
            case let status: return .failure("Margin answered with HTTP \(status ?? 0).")
            }
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .closed
        } catch {
            return .failure("Couldn't reach Margin: \(error.localizedDescription)")
        }
    }

    // MARK: Margin's core, while Margin is closed

    /// Inside the core's process: loaded on the first message; after `quiet` with none the
    /// whole process exits. Only a tool call reads the saved mail: the handshake and the tool
    /// list just need the settings.
    @MainActor final class Core {
        static let shared = Core()
        static let quiet: Duration = .seconds(300)

        private var model: MailModel?
        private var server: MCPServer?
        private var loaded = false
        private var unloading: Task<Void, Never>?

        func answer(_ body: Data) async -> Data? {
            unloading?.cancel()
            if model == nil {
                MailModel.hasNoWindow = true
                let model = MailModel(environment: SampleMode.isOn ? SampleMode.environment() : .standard)
                self.model = model
                server = model.coreServer(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
            let method = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"] as? String
            if method == "tools/call", !loaded, let model {
                await model.loadCoreForAIApps()
                loaded = true
            }
            let answer = await server?.handle(body)
            unloading = Task { [weak self] in
                try? await Task.sleep(for: Core.quiet)
                guard !Task.isCancelled else { return }
                await self?.model?.unloadCoreForAIApps()
                exit(0)
            }
            return answer
        }
    }

    /// The core's process, from the bridge's side: started on the first message while Margin
    /// is closed, one line out and one line back per message. When it has exited (quiet for a
    /// while), the next message starts it again.
    @MainActor final class CoreProcess {
        static let shared = CoreProcess()

        private var process: Process?
        private var input: FileHandle?
        private var answers: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator?

        func send(_ line: String, retrying: Bool = true) async -> Data? {
            if process?.isRunning != true { start() }
            guard let input else { return nil }
            do {
                try input.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                stop()
                return retrying ? await send(line, retrying: false) : nil
            }
            var iterator = answers
            let answer = try? await iterator?.next()
            answers = iterator
            guard let answer else {
                // It exited (quiet for a while) just as this came in: start it again, once.
                stop()
                return retrying ? await send(line, retrying: false) : nil
            }
            let data = Data(answer.utf8)
            return data == MCPBridge.noReply ? nil : data
        }

        private func start() {
            guard let executable = Bundle.main.executableURL else { return }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--mcp"] + (SampleMode.isOn ? ["-sample-mail"] : [])
            var environment = ProcessInfo.processInfo.environment
            environment[MCPBridge.coreVariable] = "1"
            process.environment = environment
            let toCore = Pipe(), fromCore = Pipe()
            process.standardInput = toCore
            process.standardOutput = fromCore
            process.standardError = FileHandle.standardError
            do { try process.run() } catch { return }
            self.process = process
            input = toCore.fileHandleForWriting
            answers = fromCore.fileHandleForReading.bytes.lines.makeAsyncIterator()
        }

        func stop() {
            if process?.isRunning == true { process?.terminate() }
            process = nil
            input = nil
            answers = nil
        }
    }

    // MARK: Telling the AI app

    /// Margin posts one signal when the AI settings change (what AI apps may do, which
    /// mailboxes they see); the app is then told its tools changed, so it asks again.
    private static func listenForSettingsChanges() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            MCPBridge.notifyToolsChanged()
            // Answering while Margin is closed was turned off: a core that's running stops now.
            Task { @MainActor in
                if !MCPBridge.settings.answersWhileClosed { CoreProcess.shared.stop() }
            }
        }, MailModel.connectionSettingsChanged as CFString, nil, .deliverImmediately)
    }

    nonisolated private static func notifyToolsChanged() {
        write(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
    }

    private static func reply(error message: String, id: Any?) {
        guard let id else { return }
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
        if let data = try? JSONSerialization.data(withJSONObject: object) { write(data) }
    }

    nonisolated private static let output = NSLock()

    /// One message per line; replies and notices come from different threads, so one at a time.
    nonisolated private static func write(_ data: Data) {
        output.lock()
        defer { output.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

