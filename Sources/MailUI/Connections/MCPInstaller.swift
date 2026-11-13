#if os(macOS)
import AppKit
import MailCore
import SwiftUI

/// Adds Margin to an AI app's MCP servers in one click, so nobody has to edit config files.
/// Apps that take an install link get one; for apps that keep a settings file, Margin adds
/// itself to that file (a sandboxed build asks once to pick it). Claude Code gets a command to paste.
enum MCPApp: String, CaseIterable, Identifiable {
    case claudeDesktop, claudeCode, chatGPT, codex, cursor, vsCode, windsurf, antigravity, lmStudio, geminiCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeDesktop: "Claude"
        case .claudeCode: "Claude Code"
        case .chatGPT: "ChatGPT"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        case .vsCode: "VS Code"
        case .windsurf: "Windsurf"
        case .lmStudio: "LM Studio"
        case .geminiCLI: "Gemini CLI"
        case .codex: "Codex"
        }
    }

    enum Method { case link, file, command }

    var method: Method {
        switch self {
        case .cursor, .vsCode, .lmStudio: .link
        case .claudeDesktop, .chatGPT, .windsurf, .antigravity, .geminiCLI, .codex: .file
        case .claudeCode: .command
        }
    }

    /// Where the app keeps its MCP servers, in the home folder.
    var configPath: String? {
        switch self {
        case .claudeDesktop: "Library/Application Support/Claude/claude_desktop_config.json"
        case .windsurf: ".codeium/windsurf/mcp_config.json"
        case .antigravity: ".gemini/antigravity/mcp_config.json"
        case .geminiCLI: ".gemini/settings.json"
        // The ChatGPT app on the Mac runs local MCP servers through Codex, from the same file.
        case .chatGPT, .codex: ".codex/config.toml"
        case .cursor, .vsCode, .lmStudio, .claudeCode: nil
        }
    }
}

@MainActor
enum MCPInstaller {
    /// The Margin apps launch: the copy in Applications when there is one, so a build run from
    /// elsewhere (Xcode, a download folder) isn't what other apps end up pointing at.
    static var executable: String {
        let installed = "/Applications/Margin.app/Contents/MacOS/Margin"
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return Bundle.main.executablePath ?? installed
    }

    /// Whether the path apps get is one that lasts (in Applications).
    static var isInstalled: Bool { executable.hasPrefix("/Applications/") }

    /// How every app starts Margin: the app itself, as a local MCP server over stdin and stdout.
    static var server: [String: Any] { ["command": executable, "args": ["--mcp"]] }

    /// Adds Margin to `app`. Returns a short note to show, or throws when it couldn't.
    static func add(to app: MCPApp, claudeCodeCommand: String) throws -> String {
        switch app.method {
        case .link:
            guard let url = try link(for: app), NSWorkspace.shared.open(url) else {
                throw MailError.notSupported(String(localized: "\(app.title) isn't installed."))
            }
            return String(localized: "\(app.title) opened to add Margin.")
        case .command:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(claudeCodeCommand, forType: .string)
            return String(localized: "Command copied. Paste it in Terminal.")
        case .file:
            // Outside the sandbox the file is written where the app keeps it; inside, the
            // person picks it once.
            guard let url = SandboxMigration.isSandboxed ? pickConfig(for: app) : app.configPath.map(Self.homeFile) else {
                throw CancellationError()
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = app.configPath?.hasSuffix(".toml") == true ? try codexConfig(existing) : try mcpServersConfig(existing)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            guard isInstalled else {
                return String(localized: "Added to \(app.title), pointing at this copy of Margin. Move Margin to Applications and add it again, or it stops working when this copy is gone.")
            }
            return String(localized: "Added to \(app.title). Restart \(app.title) to use it.")
        }
    }

    /// The install link for apps that take one.
    static func link(for app: MCPApp) throws -> URL? {
        switch app {
        case .cursor:
            // Cursor: the server entry as Base64, named separately.
            var components = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")!
            components.queryItems = [URLQueryItem(name: "name", value: "margin"),
                                     URLQueryItem(name: "config", value: try json(server).base64EncodedString())]
            return components.url
        case .lmStudio:
            // LM Studio follows Cursor's notation: the entry as Base64, named separately.
            var components = URLComponents(string: "lmstudio://add_mcp")!
            components.queryItems = [URLQueryItem(name: "name", value: "margin"),
                                     URLQueryItem(name: "config", value: try json(server).base64EncodedString())]
            return components.url
        case .vsCode:
            // VS Code: the whole entry, name included, as URL-encoded JSON after the question mark.
            var entry = server
            entry["name"] = "margin"
            let text = String(decoding: try json(entry), as: UTF8.self)
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            return URL(string: "vscode:mcp/install?" + encoded)
        default:
            return nil
        }
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// A path in the real home folder (not a sandbox container's).
    static func homeFile(_ path: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()).appending(path: path)
    }

    /// Asks once for the config file, opened at the right place with the file chosen.
    private static func pickConfig(for app: MCPApp) -> URL? {
        guard let path = app.configPath else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
        let file = home.appending(path: path)
        let panel = NSSavePanel()
        panel.message = String(localized: "Margin adds itself to \(app.title)'s settings file. Click Save to allow it.")
        panel.prompt = String(localized: "Allow")
        panel.directoryURL = file.deletingLastPathComponent()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.canCreateDirectories = true
        panel.showsTagField = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Adds or replaces `mcpServers.margin`, keeping everything else. Claude, Windsurf,
    /// Antigravity and Gemini CLI all keep their servers this way.
    static func mcpServersConfig(_ text: String) throws -> String {
        var root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["margin"] = server
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Adds or replaces the `[mcp_servers.margin]` table, keeping everything else.
    static func codexConfig(_ text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[mcp_servers.margin]" }) {
            var end = start + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            lines.removeSubrange(start..<end)
        }
        var result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty { result += "\n\n" }
        // Codex gives a server 10 seconds to start; opening Margin first can take longer.
        result += "[mcp_servers.margin]\ncommand = \"\(executable)\"\nargs = [\"--mcp\"]\nstartup_timeout_sec = 30\n"
        return result
    }
}

/// "Add Margin to" and one button per app, each one click, in an even grid.
struct MCPAddButtons: View {
    let model: MailModel
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Space.s)], alignment: .leading, spacing: Space.s) {
                ForEach(MCPApp.allCases) { app in
                    Button { add(app) } label: {
                        Text(verbatim: app.title).lineLimit(1).frame(maxWidth: .infinity)
                    }
                }
            }
            // The line is always there, so the page doesn't shift when a note appears.
            Text(verbatim: note ?? " ").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add(_ app: MCPApp) {
        let command = "claude mcp add --transport http margin \(model.connectionURL) --header \"Authorization: Bearer \(model.connectionToken)\""
        do {
            note = try MCPInstaller.add(to: app, claudeCodeCommand: command)
        } catch is CancellationError {
            note = nil
        } catch {
            note = error.localizedDescription
        }
    }
}
#endif
