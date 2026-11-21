import AppKit
import Foundation
import MailCore
import MailUI

/// `Margin --mcp`: what MCP apps launch (stdio transport). Reads JSON-RPC messages from stdin,
/// one per line, hands each to the running app's server on 127.0.0.1, and writes the replies
/// to stdout. It never opens Margin: a person who quit Margin keeps it quit. While Margin is
/// closed it answers the AI app itself, with no tools and a tool call saying Margin isn't open,
/// and when Margin is opened it tells the app its tools changed so it asks again. Logs go to
/// stderr only, because stdout belongs to the protocol.
enum MCPBridge {
    /// The settings as they are now: read again for every message, so turning things on in
    /// Margin applies without restarting the AI app.
    private static var settings: ConnectionSettings {
        defaults.data(forKey: "connectionSettings")
            .flatMap { try? JSONDecoder().decode(ConnectionSettings.self, from: $0) } ?? ConnectionSettings()
    }

    /// With `-sample-mail`, the sample app's settings and token (SampleMode.swift).
    private static var defaults: UserDefaults { SampleMode.isOn ? SampleMode.defaults : .standard }

    static func run() -> Never {
        let keychain = Keychain(service: SampleMode.isOn ? SampleMode.service : Bundle.main.bundleIdentifier ?? "app.relevate.margin")
        watchPermissions()
        watchForMargin(keychain: keychain)

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"]
            let settings = settings
            let url = URL(string: "http://127.0.0.1:\(settings.port)/mcp")!
            guard settings.enabled else {
                reply(error: "Margin's connection is off. Turn on Settings → AI Apps → Let AI apps use Margin.", id: id)
                continue
            }
            guard let token = token(in: keychain) else {
                reply(error: "Margin couldn't read its connection token from the Keychain.", id: id)
                continue
            }
            switch post(Data(line.utf8), to: url, token: token) {
            case .success(let body?):
                setClosed(false)
                write(body)
            case .success(nil):
                setClosed(false) // a notification: nothing to send back
            case .closed:
                setClosed(true)
                if let body = closedAnswer(to: Data(line.utf8)) { write(body) }
            case .failure(let message):
                reply(error: message, id: id)
            }
        }
        exit(0)
    }

    /// The shared token: made here when Margin hasn't made one yet; the app reads the same item.
    private static func token(in keychain: Keychain) -> String? {
        if let token = keychain.read(key: "mcp.token") { return token }
        let token = MCPHTTPServer.makeToken()
        return (try? keychain.save(token, key: "mcp.token")) != nil ? token : nil
    }

    enum Outcome { case success(Data?), closed, failure(String) }

    // MARK: While Margin is closed

    nonisolated(unsafe) private static var isClosed = false
    private static let closedLock = NSLock()

    private static func setClosed(_ closed: Bool) {
        closedLock.lock()
        isClosed = closed
        closedLock.unlock()
    }

    private static var marginIsClosed: Bool {
        closedLock.lock()
        defer { closedLock.unlock() }
        return isClosed
    }

    /// No tools while Margin is closed; a call says so, for the AI app to pass on.
    struct ClosedToolbox: MCPToolbox {
        func tools() async -> [MCPTool] { [] }
        func call(_ name: String, arguments: [String: MCPValue]) async throws -> String {
            throw MCPToolError("Margin isn't open. Ask the person to open Margin, then try again; its tools come back once it's open.")
        }
        func content(_ name: String, arguments: [String: MCPValue]) async throws -> [MCPContent] {
            [.text(try await call(name, arguments: arguments))]
        }
    }

    /// The answer to a message while Margin is closed, from a server with no tools: the
    /// handshake still works, so the AI app keeps the connection for when Margin opens.
    private static func closedAnswer(to body: Data) -> Data? {
        let server = MCPServer(toolbox: ClosedToolbox(), name: "Margin",
                               version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: Data?
        Task.detached {
            answer = await server.handle(body)
            done.signal()
        }
        done.wait()
        return answer
    }

    /// While Margin is closed, a quiet look every few seconds; when it's open again, the AI app
    /// is told its tools changed, so it asks for them.
    private static func watchForMargin(keychain: Keychain) {
        Thread.detachNewThread { @Sendable in
            while true {
                Thread.sleep(forTimeInterval: 3)
                guard marginIsClosed else { continue }
                let settings = settings
                guard settings.enabled, let url = URL(string: "http://127.0.0.1:\(settings.port)/mcp"),
                      let token = keychain.read(key: "mcp.token") else { continue }
                let ping = Data(#"{"jsonrpc":"2.0","id":"margin-open","method":"ping"}"#.utf8)
                if case .success = post(ping, to: url, token: token) {
                    setClosed(false)
                    write(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
                }
            }
        }
    }

    private static func post(_ body: Data, to url: URL, token: String) -> Outcome {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = Outcome.failure("Margin didn't answer.")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as NSError? {
                outcome = error.code == NSURLErrorCannotConnectToHost ? .closed
                    : .failure("Couldn't reach Margin: \(error.localizedDescription)")
            } else if let status = (response as? HTTPURLResponse)?.statusCode {
                switch status {
                case 200: outcome = .success(data)
                case 202: outcome = .success(nil)
                case 401: outcome = .failure("Margin refused the connection token. Copy the setup again from Margin's settings.")
                default: outcome = .failure("Margin answered with HTTP \(status).")
                }
            }
            done.signal()
        }.resume()
        done.wait()

        return outcome
    }

    private static func reply(error message: String, id: Any?) {
        guard let id else { return }
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
        if let data = try? JSONSerialization.data(withJSONObject: object) { write(data) }
    }

    /// When what AI apps may do changes in Margin (Allow changes, sending, settings, which
    /// mailboxes they see), tell the app its tool list changed, so it asks again instead of
    /// keeping the tools it was given when it connected. It runs on its own thread, so it only
    /// compares the saved settings as they are, without decoding them (that belongs to the main
    /// thread).
    private static func watchPermissions() {
        Thread.detachNewThread { @Sendable in
            var last = defaults.data(forKey: "connectionSettings")
            while true {
                Thread.sleep(forTimeInterval: 1.5)
                let now = defaults.data(forKey: "connectionSettings")
                guard now != last else { continue }
                last = now
                let notice = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
                write(notice)
            }
        }
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
