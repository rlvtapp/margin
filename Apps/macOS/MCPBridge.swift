import AppKit
import Foundation
import MailCore
import MailUI

/// `Margin --mcp`: what MCP apps launch (stdio transport). Reads JSON-RPC messages from stdin,
/// one per line, hands each to the running app's server on 127.0.0.1, and writes the replies
/// to stdout. Opens Margin in the background when it isn't running. Logs go to stderr only,
/// because stdout belongs to the protocol.
enum MCPBridge {
    /// The settings as they are now: read again for every message, so turning things on in
    /// Margin applies without restarting the AI app.
    private static var settings: ConnectionSettings {
        UserDefaults.standard.data(forKey: "connectionSettings")
            .flatMap { try? JSONDecoder().decode(ConnectionSettings.self, from: $0) } ?? ConnectionSettings()
    }

    static func run() -> Never {
        let keychain = Keychain(service: Bundle.main.bundleIdentifier ?? "app.relevate.margin")
        watchPermissions()

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"]
            let settings = settings
            let url = URL(string: "http://127.0.0.1:\(settings.port)/mcp")!
            guard settings.enabled else {
                reply(error: "Margin's connection is off. Turn on Settings → Connections → Let AI apps use Margin.", id: id)
                continue
            }
            guard let token = token(in: keychain) else {
                reply(error: "Margin couldn't read its connection token from the Keychain.", id: id)
                continue
            }
            switch post(Data(line.utf8), to: url, token: token, launchingIfNeeded: true) {
            case .success(let body?):
                write(body)
            case .success(nil):
                break // a notification: nothing to send back
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

    enum Outcome { case success(Data?), failure(String) }

    private static func post(_ body: Data, to url: URL, token: String, launchingIfNeeded: Bool) -> Outcome {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = Outcome.failure("Margin didn't answer.")
        nonisolated(unsafe) var refused = false
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as NSError? {
                refused = error.code == NSURLErrorCannotConnectToHost
                outcome = .failure("Couldn't reach Margin: \(error.localizedDescription)")
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

        // Not running: open Margin quietly and try again for a few seconds.
        if refused && launchingIfNeeded {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.5)
                let retry = post(body, to: url, token: token, launchingIfNeeded: false)
                if case .failure(let message) = retry, message.hasPrefix("Couldn't reach") { continue }
                return retry
            }
        }
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
            var last = UserDefaults.standard.data(forKey: "connectionSettings")
            while true {
                Thread.sleep(forTimeInterval: 1.5)
                let now = UserDefaults.standard.data(forKey: "connectionSettings")
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
