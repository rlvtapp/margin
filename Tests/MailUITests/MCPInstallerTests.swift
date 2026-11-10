#if os(macOS)
import Foundation
import Testing
@testable import MailUI

@MainActor @Suite struct MCPInstallerTests {
    @Test func addsMarginToMCPServersKeepingEverythingElse() throws {
        let before = #"{"mcpServers":{"files":{"command":"/bin/files"}},"theme":"dark"}"#
        let after = try MCPInstaller.mcpServersConfig(before)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["files"] != nil)
        #expect((servers["margin"] as? [String: Any])?["args"] as? [String] == ["--mcp"])
        #expect(root["theme"] as? String == "dark")
    }

    @Test func startsAFreshSettingsFile() throws {
        let after = try MCPInstaller.mcpServersConfig("")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])
        #expect(((root["mcpServers"] as? [String: Any])?["margin"] as? [String: Any])?["command"] as? String == MCPInstaller.executable)
    }

    @Test func linksCarryTheServer() throws {
        func config(_ url: URL) throws -> [String: Any] {
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.first { $0.name == "name" }?.value == "margin")
            let encoded = try #require(items.first { $0.name == "config" }?.value)
            let data = try #require(Data(base64Encoded: encoded))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let cursor = try #require(try MCPInstaller.link(for: .cursor))
        #expect(cursor.absoluteString.hasPrefix("cursor://anysphere.cursor-deeplink/mcp/install?"))
        #expect(try config(cursor)["args"] as? [String] == ["--mcp"])

        let lmStudio = try #require(try MCPInstaller.link(for: .lmStudio))
        #expect(lmStudio.absoluteString.hasPrefix("lmstudio://add_mcp?"))
        #expect(try config(lmStudio)["command"] as? String == MCPInstaller.executable)

        let vsCode = try #require(try MCPInstaller.link(for: .vsCode))
        #expect(vsCode.absoluteString.hasPrefix("vscode:mcp/install?"))
        let payload = try #require(vsCode.absoluteString.dropFirst("vscode:mcp/install?".count).removingPercentEncoding)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(entry["name"] as? String == "margin")
        #expect(entry["args"] as? [String] == ["--mcp"])

        #expect(try MCPInstaller.link(for: .windsurf) == nil)
    }

    @Test func everyAppHasAWayIn() {
        for app in MCPApp.allCases {
            switch app.method {
            case .file: #expect(app.configPath != nil, "\(app.title) needs a settings file")
            case .link, .command: #expect(app.configPath == nil)
            }
        }
    }

    @Test func chatGPTSharesCodexSettings() {
        #expect(MCPApp.chatGPT.configPath == MCPApp.codex.configPath)
        #expect(MCPApp.antigravity.configPath == ".gemini/antigravity/mcp_config.json")
    }

    @Test func replacesMarginInCodexConfig() throws {
        let before = "model = \"o4\"\n\n[mcp_servers.margin]\ncommand = \"/old\"\nargs = []\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        let after = try MCPInstaller.codexConfig(before)
        #expect(after.components(separatedBy: "[mcp_servers.margin]").count == 2)
        #expect(!after.contains("/old"))
        #expect(after.contains("[mcp_servers.other]"))
        #expect(after.contains("model = \"o4\""))
    }
}
#endif
