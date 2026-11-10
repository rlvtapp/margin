import Foundation
import MailCore

/// A group of mailboxes, like Work or Personal. While one is chosen, the rail, All Inboxes,
/// Home, VIPs and the counts show only its mailboxes, and the others check mail quietly.
public struct Workspace: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var colorIndex: Int
    public var accounts: [UUID]

    public init(name: String, colorIndex: Int, accounts: [UUID]) {
        self.name = name
        self.colorIndex = colorIndex
        self.accounts = accounts
    }
}

extension MailModel {
    public var workspaces: [Workspace] {
        get {
            _ = workspaceRevision
            guard let data = environment.defaults.data(forKey: "workspaces") else { return [] }
            return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
        }
        set {
            environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "workspaces")
            if let current = currentWorkspaceID, !newValue.contains(where: { $0.id == current }) { currentWorkspaceID = nil }
            workspaceRevision += 1
        }
    }

    /// The chosen workspace; nil shows every mailbox.
    public var currentWorkspaceID: UUID? {
        get { _ = workspaceRevision; return environment.defaults.string(forKey: "currentWorkspace").flatMap(UUID.init(uuidString:)) }
        set { environment.defaults.set(newValue?.uuidString, forKey: "currentWorkspace"); workspaceRevision += 1 }
    }

    public var currentWorkspace: Workspace? { workspaces.first { $0.id == currentWorkspaceID } }

    /// The mailboxes in view: the chosen workspace's, or all of them.
    public var workspaceAccounts: [MailAccount] {
        guard let workspace = currentWorkspace else { return accounts }
        return accounts.filter { workspace.accounts.contains($0.id) }
    }

    public func switchWorkspace(to id: UUID?) {
        currentWorkspaceID = id
        selection = []
        selectedThreadID = nil
        go(to: layout == .minimal ? .home(group: nil) : .allInboxes)
    }

    /// Whether a conversation belongs to a workspace that isn't the one in view.
    func isInOtherWorkspace(_ thread: MailThread) -> Bool {
        guard let workspace = currentWorkspace, let account = thread.accountID else { return false }
        return !workspace.accounts.contains(account)
    }

    /// Unread mail waiting in a workspace, for the dot beside it.
    public func unreadCount(in workspace: Workspace) -> Int {
        workspace.accounts.reduce(0) { $0 + inboxThreads($1).filter(\.isUnread).count }
    }

    public func addWorkspace(named name: String) {
        var all = workspaces
        all.append(Workspace(name: name, colorIndex: (all.count * 3 + 1) % 12, accounts: []))
        workspaces = all
    }
}
