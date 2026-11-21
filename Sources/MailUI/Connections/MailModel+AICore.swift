import Foundation
import MailCore

/// Margin's core for AI apps while Margin itself is closed (docs/intelligence.md, "While Margin
/// is closed"). The AI app's connection (`Margin --mcp`) loads it only when a request comes in
/// and Margin isn't open, and unloads it after a few quiet minutes. It reads what's on this Mac
/// (saved mail, people, the calendars) and can change events in their own calendars when
/// changes are allowed; it never syncs mail, sends, or changes mail, so it can't get in the way
/// of Margin opening at the same time. Nothing runs in the background: no clock, no checks.
extension MailModel {
    /// What a tool call needs: the mail and people saved on this Mac, and the API sign-ins.
    public func loadCoreForAIApps() async {
        loadVerdicts()
        await loadSavedMail()
        for account in accounts { await loadSavedSentMail(for: account) }
        fillPlaceholderNames()
        await loadAPIAccess()
    }

    /// Closes any server connection a tool opened, so nothing is left running.
    public func unloadCoreForAIApps() async {
        for provider in providers.values { await provider.disconnect() }
        providers = [:]
    }

    /// The protocol server the core answers with: Margin's own tools, limited to reading, and
    /// the calendar's changes when the person allows changes. Anything else says to open Margin.
    public func coreServer(version: String) -> MCPServer {
        MCPServer(toolbox: CoreToolbox(model: self), name: environment.appName, version: version)
    }
}

/// Margin's tools as the core offers them.
struct CoreToolbox: MCPToolbox {
    let model: MailModel

    /// Tools that only make sense with Margin on screen.
    static let needsTheApp: Set<String> = ["create_draft", "get_selection"]

    private func allowed() async -> (permissions: ConnectionSettings, names: Set<String>) {
        let settings = await model.connectionSettings
        var reading = settings
        reading.allowChanges = false
        reading.allowSending = false
        reading.allowSettings = false
        let readNames = Set(await MailToolbox(model: model, permissions: reading).tools().map(\.name)).subtracting(Self.needsTheApp)
        var permissions = settings
        permissions.allowSending = false
        permissions.allowSettings = false
        var calendarChanges: Set<String> = []
        if settings.allowChanges {
            calendarChanges = Set(CalendarTools.tools(allowChanges: true).map(\.name)).subtracting(CalendarTools.tools(allowChanges: false).map(\.name))
        }
        return (permissions, readNames.union(calendarChanges))
    }

    func tools() async -> [MCPTool] {
        let allowed = await allowed()
        return await MailToolbox(model: model, permissions: allowed.permissions, only: allowed.names).tools()
    }

    func call(_ name: String, arguments: [String: MCPValue]) async throws -> String {
        let allowed = await allowed()
        guard allowed.names.contains(name) else {
            throw MCPToolError("Margin is closed, so this can't be done now. Ask the person to open Margin, then try again.")
        }
        return try await MailToolbox(model: model, permissions: allowed.permissions, only: allowed.names).call(name, arguments: arguments)
    }

    func content(_ name: String, arguments: [String: MCPValue]) async throws -> [MCPContent] {
        let allowed = await allowed()
        guard allowed.names.contains(name) else { return [.text(try await call(name, arguments: arguments))] }
        return try await MailToolbox(model: model, permissions: allowed.permissions, only: allowed.names).content(name, arguments: arguments)
    }
}
