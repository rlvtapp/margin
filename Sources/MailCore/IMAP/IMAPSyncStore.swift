import Foundation

/// What each IMAP folder held at the last refresh, kept between launches, so the first check
/// after starting asks only for what changed instead of downloading every inbox's newest 200
/// messages again (9 s at launch for four mailboxes, most of it Outlook.com). One file per
/// mailbox in the app's own folder, next to the saved mail; it holds the same headers and
/// previews that saved mail does, never a body, password or token.
public actor IMAPSyncStore {
    private let folder: URL
    private var written: [UUID: ContinuousClock.Instant] = [:]

    public init(folder: URL) {
        self.folder = folder
    }

    /// The bump in `version` when the format changes: an older file is then simply not read.
    struct Saved: Codable {
        static let currentVersion = 1
        var version = Saved.currentVersion
        /// Which server and sign-in the state belongs to. A mailbox moved to another server
        /// (or another user name) starts afresh.
        var server: String
        var folders: [String: IMAPFolderSync]
    }

    private func file(_ account: UUID) -> URL { folder.appending(path: "\(account.uuidString).json") }

    func load(account: UUID, server: String) -> [String: IMAPFolderSync] {
        guard let data = try? Data(contentsOf: file(account)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == Saved.currentVersion, saved.server == server else { return [:] }
        return saved.folders
    }

    /// Writes the state as it was at `taken`; a later state that was written first wins.
    func save(_ folders: [String: IMAPFolderSync], account: UUID, server: String, taken: ContinuousClock.Instant) {
        if let last = written[account], last >= taken { return }
        written[account] = taken
        guard let data = try? JSONEncoder().encode(Saved(server: server, folders: folders)) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(account), options: .atomic)
    }

    /// Forgets mailboxes that were removed.
    public func keepOnly(_ accounts: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !accounts.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
