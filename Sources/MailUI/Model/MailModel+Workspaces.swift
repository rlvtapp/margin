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

    /// The mailboxes in view: the chosen workspace's, or all of them. A mailbox that's in no
    /// workspace at all (just added, or its workspace was deleted) shows in every one: nobody
    /// chose to hide it, and a mailbox must never drop out of the account column by itself.
    public var workspaceAccounts: [MailAccount] {
        guard let workspace = currentWorkspace else { return accounts }
        let grouped = Set(workspaces.flatMap(\.accounts))
        return accounts.filter { workspace.accounts.contains($0.id) || !grouped.contains($0.id) }
    }

    /// Puts mailboxes in the order you want: the account column, sidebar, All inboxes and the
    /// ⌃2, ⌃3… shortcuts all follow it.
    public func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        try? environment.accounts.save(accounts)
    }

    /// Moves one mailbox up (-1) or down (1) a place.
    public func moveAccount(_ id: UUID, by step: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + step
        guard accounts.indices.contains(target) else { return }
        accounts.swapAt(index, target)
        try? environment.accounts.save(accounts)
    }

    /// Moves a dragged mailbox to where another one is.
    public func moveAccount(_ id: UUID, to other: UUID) {
        guard id != other, let from = accounts.firstIndex(where: { $0.id == id }),
              let to = accounts.firstIndex(where: { $0.id == other }) else { return }
        accounts.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        try? environment.accounts.save(accounts)
    }

    /// Puts these mailboxes in this order, in the places they already take among the others
    /// (the account column shows one workspace's mailboxes, not always all of them).
    public func setAccountOrder(_ ids: [UUID]) {
        let places = accounts.indices.filter { ids.contains(accounts[$0].id) }
        let wanted = ids.compactMap { id in accounts.first { $0.id == id } }
        guard places.count == wanted.count else { return }
        var reordered = accounts
        for (place, account) in zip(places, wanted) { reordered[place] = account }
        guard reordered.map(\.id) != accounts.map(\.id) else { return }
        accounts = reordered
        try? environment.accounts.save(accounts)
    }

    func canMoveAccount(_ id: UUID, by step: Int) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
        return accounts.indices.contains(index + step)
    }

    public func switchWorkspace(to id: UUID?) {
        currentWorkspaceID = id
        selection = []
        selectedThreadID = nil
        go(to: layout == .minimal ? .home(group: nil) : .allInboxes)
    }

    /// Whether a conversation belongs to a workspace that isn't the one in view.
    func isInOtherWorkspace(_ thread: MailThread) -> Bool {
        guard currentWorkspace != nil, let account = thread.accountID else { return false }
        return !workspaceAccounts.contains { $0.id == account }
    }

    /// Unread mail waiting in a workspace, for the dot beside it.
    public func unreadCount(in workspace: Workspace) -> Int {
        _ = inboxRevision
        return workspace.accounts.reduce(0) { $0 + (shelves[$1]?.unreadCount(split: nil) ?? 0) }
    }

    public func addWorkspace(named name: String) {
        var all = workspaces
        all.append(Workspace(name: name, colorIndex: (all.count * 3 + 1) % 12, accounts: []))
        workspaces = all
    }
}
