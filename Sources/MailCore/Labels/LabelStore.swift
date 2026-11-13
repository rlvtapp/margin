import Foundation

/// Labels on conversations, kept on this device as JSON. Not every protocol has labels
/// (IMAP keywords are patchy across servers), so Margin keeps its own.
public struct LabelStore: Sendable {
    public let fileURL: URL
    public private(set) var labelsByThread: [String: [String]] {
        didSet { revision &+= 1 }
    }
    /// Goes up with every change to the labels, so what depends on them can tell "changed" from
    /// "the same" without walking through every labelled conversation.
    public private(set) var revision = 0

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        labelsByThread = data.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    public static func standard(appName: String) -> LabelStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LabelStore(fileURL: base.appending(path: appName, directoryHint: .isDirectory).appending(path: "labels.json"))
    }

    /// The key a conversation's labels are stored under: its account and first Message-ID,
    /// which survive moving between folders (IMAP UIDs don't).
    public static func key(for thread: MailThread) -> String {
        let first = thread.messages.first
        return "\(thread.accountID?.uuidString ?? "-")|\(first?.messageID ?? thread.id)"
    }

    public func labels(for thread: MailThread) -> [String] {
        labelsByThread[Self.key(for: thread)] ?? []
    }

    /// Every label in use, most used first.
    public var allLabels: [String] {
        var counts: [String: Int] = [:]
        for labels in labelsByThread.values { for label in labels { counts[label, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    public mutating func add(_ label: String, to thread: MailThread) {
        let key = Self.key(for: thread)
        var labels = labelsByThread[key] ?? []
        guard !labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else { return }
        labels.append(label)
        labelsByThread[key] = labels
        save()
    }

    /// Every conversation's labels at once, as they arrived from iCloud.
    public mutating func replaceAll(with labels: [String: [String]]) {
        guard labels != labelsByThread else { return }
        labelsByThread = labels.filter { !$0.value.isEmpty }
        save()
    }

    public mutating func remove(_ label: String, from thread: MailThread) {
        let key = Self.key(for: thread)
        labelsByThread[key]?.removeAll { $0.caseInsensitiveCompare(label) == .orderedSame }
        if labelsByThread[key]?.isEmpty == true { labelsByThread[key] = nil }
        save()
    }

    /// How many conversations carry each label.
    public var counts: [String: Int] {
        var counts: [String: Int] = [:]
        for labels in labelsByThread.values { for label in labels { counts[label, default: 0] += 1 } }
        return counts
    }

    /// Renames a label everywhere (matching ignores case). Where a conversation already has
    /// the new name, the two become one. Returns how many conversations changed.
    @discardableResult
    public mutating func rename(_ label: String, to newName: String) -> Int {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return 0 }
        var changed = 0
        for (key, labels) in labelsByThread where labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
            var renamed: [String] = []
            for current in labels {
                let next = current.caseInsensitiveCompare(label) == .orderedSame ? name : current
                if !renamed.contains(where: { $0.caseInsensitiveCompare(next) == .orderedSame }) { renamed.append(next) }
            }
            labelsByThread[key] = renamed
            changed += 1
        }
        if changed > 0 { save() }
        return changed
    }

    /// Takes a label off every conversation (matching ignores case). Returns how many changed.
    @discardableResult
    public mutating func delete(_ label: String) -> Int {
        var changed = 0
        for (key, labels) in labelsByThread where labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
            let kept = labels.filter { $0.caseInsensitiveCompare(label) != .orderedSame }
            labelsByThread[key] = kept.isEmpty ? nil : kept
            changed += 1
        }
        if changed > 0 { save() }
        return changed
    }

    /// Puts every label back as it was in `snapshot` (an earlier `labelsByThread`).
    public mutating func restore(_ snapshot: [String: [String]]) {
        labelsByThread = snapshot
        save()
    }

    /// Adds labels from a backup, keeping what's already here.
    public mutating func merge(_ other: [String: [String]]) {
        for (key, labels) in other {
            var current = labelsByThread[key] ?? []
            for label in labels where !current.contains(label) { current.append(label) }
            labelsByThread[key] = current
        }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(labelsByThread).write(to: fileURL, options: .atomic)
    }
}
