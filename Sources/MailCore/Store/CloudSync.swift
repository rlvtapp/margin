import Foundation

/// Mailboxes, settings, templates and workspaces in your private iCloud Drive (Margin's own
/// container), so every Mac, iPhone and iPad signed in to the same Apple Account has them.
/// Apple moves the files; nothing goes through a server of ours. Passwords travel separately,
/// in iCloud Keychain. Needs a build signed with an iCloud container (docs/icloud.md).
///
/// Each kind of data is one file of items by key. Each device remembers what it last synced, so
/// it knows what changed here: those changes go up with the time they were noticed, everything
/// else comes down. Deletions leave a tombstone for 60 days so an offline device can't bring
/// an item back.
public enum CloudSync {
    /// One synced file: items by key, and when deleted ones were deleted.
    public struct Set: Codable, Equatable, Sendable {
        public var items: [String: Entry] = [:]
        public var deleted: [String: Date] = [:]

        public init(items: [String: Entry] = [:], deleted: [String: Date] = [:]) {
            self.items = items
            self.deleted = deleted
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var data: Data
        public var updatedAt: Date

        public init(data: Data, updatedAt: Date) {
            self.data = data
            self.updatedAt = updatedAt
        }
    }

    /// Margin's folder in iCloud Drive, or nil when this build or device has no iCloud.
    public static func folder() -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil,
              let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        return container.appending(path: "Documents", directoryHint: .isDirectory)
    }

    /// Why sync can't run, in plain words, or nil when it can.
    public static var unavailableReason: String? {
        if FileManager.default.ubiquityIdentityToken == nil {
            return String(localized: "Sign in to iCloud with iCloud Drive on to sync.")
        }
        if FileManager.default.url(forUbiquityContainerIdentifier: nil) == nil {
            return String(localized: "This build of Margin isn't signed for iCloud. See docs/icloud.md.")
        }
        return nil
    }

    /// Merges this device's items with the synced file.
    /// - Parameters:
    ///   - current: the items here now, encoded.
    ///   - lastSynced: the items as they were after this device's last sync.
    ///   - remote: the synced file.
    /// - Returns: the items this device should now have, and the file to write back.
    public static func merge(current: [String: Data], lastSynced: [String: Data], remote: Set,
                             now: Date = Date()) -> (items: [String: Data], remote: Set) {
        var out = remote
        out.deleted = out.deleted.filter { now.timeIntervalSince($0.value) < 60 * 86_400 }
        for key in Swift.Set(current.keys).union(lastSynced.keys) where current[key] != lastSynced[key] {
            if let value = current[key] {
                // Changed or added here. A newer change from elsewhere still wins.
                if let theirs = out.items[key], theirs.updatedAt > now { continue }
                out.items[key] = Entry(data: value, updatedAt: now)
                out.deleted[key] = nil
            } else {
                // Removed here.
                out.items[key] = nil
                out.deleted[key] = now
            }
        }
        for (key, date) in out.deleted where (out.items[key]?.updatedAt).map({ $0 <= date }) ?? false {
            out.items[key] = nil
        }
        return (out.items.mapValues(\.data), out)
    }

    // MARK: Files

    public static func read(_ name: String, in folder: URL) -> Set {
        guard let data = coordinatedRead(folder.appending(path: "\(name).json")) else { return Set() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Set.self, from: data)) ?? Set()
    }

    public static func write(_ set: Set, name: String, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(set) { coordinatedWrite(data, to: folder.appending(path: "\(name).json")) }
    }

    /// iCloud Drive files are read and written through a file coordinator, so a download in
    /// progress is waited for and never half-read.
    static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = try? Data(contentsOf: url)
        }
        return result
    }

    static func coordinatedWrite(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Encodes the same value the same way every time, so a change can be noticed by comparing.
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
