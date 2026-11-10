import Foundation
import MailCore

/// The MCP connection: a server on 127.0.0.1 that AI apps (Claude Desktop, Claude Code,
/// ChatGPT, others) use to search and read mail, and, when allowed, to act on it.
extension MailModel {
    static let tokenKey = "mcp.token"

    /// The bearer token AI apps send. Made once and kept in the Keychain.
    public var connectionToken: String {
        if let token = environment.keychain.read(key: Self.tokenKey) { return token }
        let token = MCPHTTPServer.makeToken()
        try? environment.keychain.save(token, key: Self.tokenKey)
        return token
    }

    public var connectionURL: String { "http://127.0.0.1:\(connectionSettings.port)/mcp" }

    public func applyConnections(_ settings: ConnectionSettings) {
        connectionSettings = settings
        environment.defaults.set(try? JSONEncoder().encode(settings), forKey: "connectionSettings")
        restartConnection()
    }

    /// A new token; apps set up with the old one have to be updated.
    public func resetConnectionToken() {
        environment.keychain.delete(key: Self.tokenKey)
        _ = connectionToken
        restartConnection()
    }

    public func startConnectionIfEnabled() {
        if connectionSettings.enabled && mcpServer == nil { restartConnection() }
    }

    func restartConnection() {
        mcpServer?.stop()
        mcpServer = nil
        connectionError = nil
        guard connectionSettings.enabled else { return }
        let server = makeConnectionServer(port: connectionSettings.port, token: connectionToken)
        do {
            try server.start()
            mcpServer = server
        } catch {
            connectionError = String(localized: "Couldn't listen on port \(connectionSettings.port). Another app may be using it.")
        }
    }

    /// The MCP server with Margin's tools, logging each call to Recent activity.
    func makeConnectionServer(port: UInt16, token: String) -> MCPHTTPServer {
        let protocolServer = MCPServer(toolbox: MailToolbox(model: self), name: environment.appName, version: "0.1.0") { [weak self] tool in
            Task { @MainActor in self?.noteActivity(tool) }
        }
        return MCPHTTPServer(port: port, token: token, server: protocolServer)
    }

    private func noteActivity(_ tool: String) {
        connectionActivity.insert(MCPActivity(date: Date(), tool: tool), at: 0)
        if connectionActivity.count > 30 { connectionActivity.removeLast() }
    }
}
