#if os(macOS)
import Foundation

/// Margin used to run in the macOS sandbox, which kept its files and settings in a private
/// container (~/Library/Containers/<bundle id>). Outside the sandbox it looks in the usual
/// places. On the first launch outside, everything the container holds is copied over, so
/// mailboxes, settings, rules and saved mail are all there. The container is left as it was,
/// as a copy to fall back on.
public enum SandboxMigration {
    static let doneKey = "migratedFromSandbox"

    /// Whether this process runs in the sandbox (then there's nothing to move).
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// Copies the container's files and settings once. Returns what was copied, for the log.
    @discardableResult
    public static func runIfNeeded(bundleID: String? = Bundle.main.bundleIdentifier, appName: String = "Margin") -> [String] {
        guard !isSandboxed, let bundleID else { return [] }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return run(bundleID: bundleID, appName: appName, home: home, defaults: .standard)
    }

    /// The move itself, with every place given, so it can be tried on a made-up home folder.
    static func run(bundleID: String, appName: String, home: URL, defaults: UserDefaults,
                    fileManager: FileManager = .default) -> [String] {
        guard !defaults.bool(forKey: doneKey) else { return [] }
        let container = home.appending(path: "Library/Containers/\(bundleID)/Data", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: container.path) else {
            // Never sandboxed on this Mac: nothing to bring over.
            defaults.set(true, forKey: doneKey)
            return []
        }
        var copied: [String] = []
        // Files: everything the sandboxed Margin kept under Application Support. What's
        // already here (pictures cached by a test run) stays; the rest comes over.
        let old = container.appending(path: "Library/Application Support/\(appName)", directoryHint: .isDirectory)
        let new = home.appending(path: "Library/Application Support/\(appName)", directoryHint: .isDirectory)
        copied += copyMissing(from: old, to: new, fileManager: fileManager)
        // Settings: the container's preferences win, since they're the ones that were in use.
        let preferences = container.appending(path: "Library/Preferences/\(bundleID).plist")
        if let values = NSDictionary(contentsOf: preferences) as? [String: Any] {
            for (key, value) in values where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple.") {
                defaults.set(value, forKey: key)
            }
            copied.append("settings (\(values.count))")
        }
        defaults.set(true, forKey: doneKey)
        return copied
    }

    /// Copies each item of `source` that `destination` doesn't have; folders that exist on
    /// both sides are merged the same way.
    static func copyMissing(from source: URL, to destination: URL, fileManager: FileManager) -> [String] {
        guard let items = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied: [String] = []
        for item in items {
            let target = destination.appending(path: item.lastPathComponent)
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if fileManager.fileExists(atPath: target.path) {
                if isFolder { copied += copyMissing(from: item, to: target, fileManager: fileManager) }
                continue
            }
            if (try? fileManager.copyItem(at: item, to: target)) != nil { copied.append(item.lastPathComponent) }
        }
        return copied
    }
}
#endif
