import Foundation
import MailCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Moving Margin to another device, a recovery key for backups, undoing a restore, and
/// noticing when automatic backups stop working.
public enum DeviceLink {
    /// Files made by "Link Another Device…".
    public static let fileExtension = "marginlink"
}

/// What was here before a restore, so it can be put back.
struct RestoreUndo {
    var accounts: [MailAccount]
    var templates: [MailTemplate]
    var labels: [String: [String]]
    var snoozes: [String: Date]
    var outbox: [ScheduledMessage]
    var trustedPictureSenders: Set<String>
    var settings: [String: Any]
    var writingProfile: WritingProfile
    var askChats: [AskChat]
}

extension MailModel {
    // MARK: Link another device

    /// Writes everything (mailboxes with their passwords, settings, labels, templates) to a
    /// file locked with a fresh short code. Send the file to the other device (AirDrop works),
    /// open it there, and type the code.
    public func makeDeviceLink() throws -> (file: URL, code: String) {
        let code = BackupBox.makeLinkCode()
        let data = try makeBackup(password: BackupBox.normalized(code), includeSecrets: true, recoveryKey: nil)
        let folder = FileManager.default.temporaryDirectory.appending(path: "Margin Link \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: String(localized: "Margin Settings", comment: "Device link file name, without extension") + ".\(DeviceLink.fileExtension)")
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        return (file, code)
    }

    /// Brings in a device-link file opened from another device, with the code shown there.
    public func acceptDeviceLink(code: String) throws -> String {
        guard let url = pendingDeviceLink else { throw BackupBox.Failure.notABackup }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let result = try restore(data, password: BackupBox.normalized(code), parts: .all)
        pendingDeviceLink = nil
        return result
    }

    // MARK: Recovery key

    /// The recovery key that also opens password-protected backups, when one was made.
    public var backupRecoveryKey: String? {
        _ = backupRevision
        return environment.keychain.read(key: "backupRecoveryKey")
    }

    /// Makes a new recovery key, kept in the Keychain. Backups made from now on open with it too.
    @discardableResult
    public func makeBackupRecoveryKey() -> String {
        let key = BackupBox.makeRecoveryKey()
        try? environment.keychain.save(key, key: "backupRecoveryKey")
        backupRevision += 1
        return key
    }

    public func removeBackupRecoveryKey() {
        environment.keychain.delete(key: "backupRecoveryKey")
        backupRevision += 1
    }

    // MARK: Undoing a restore

    func snapshotForRestore() -> RestoreUndo {
        var settings: [String: Any] = [:]
        for key in Self.backedUpSettings { settings[key] = environment.defaults.object(forKey: key) }
        return RestoreUndo(accounts: accounts, templates: templates, labels: labelStore.labelsByThread, snoozes: snoozes,
                           outbox: outbox, trustedPictureSenders: trustedPictureSenders, settings: settings,
                           writingProfile: writingProfile, askChats: askChats)
    }

    public var canUndoRestore: Bool { restoreUndo != nil }

    /// Puts everything back as it was before the last restore. Mailboxes the restore added are
    /// removed again, with their passwords.
    public func undoRestore() {
        guard let before = restoreUndo else { return }
        restoreUndo = nil
        let kept = Set(before.accounts.map(\.id))
        for account in accounts where !kept.contains(account.id) {
            for kind in ["password", "oauth", "token"] { environment.keychain.delete(key: "\(account.id.uuidString).\(kind)") }
            providers[account.id] = nil
        }
        accounts = before.accounts
        try? environment.accounts.save(accounts)
        templates = before.templates
        saveTemplates()
        labelStore.restore(before.labels)
        snoozes = before.snoozes
        saveSnoozes()
        outbox = before.outbox
        saveOutbox()
        trustedPictureSenders = before.trustedPictureSenders
        environment.defaults.set(Array(trustedPictureSenders).sorted(), forKey: "trustedPictureSenders")
        for key in Self.backedUpSettings {
            if let value = before.settings[key] { environment.defaults.set(value, forKey: key) } else { environment.defaults.removeObject(forKey: key) }
        }
        applyStoredSettings()
        writingProfile = before.writingProfile
        askChats = before.askChats
        notice = Notice(text: String(localized: "Restore undone"))
        Task { await reload() }
    }

    // MARK: When automatic backups stop working

    /// Why the last automatic backup failed; cleared by the next one that works.
    public var automaticBackupProblem: String? {
        _ = backupRevision
        return environment.defaults.string(forKey: "automaticBackupProblem")
    }

    func noteAutomaticBackupFailed(_ error: Error) {
        let alreadyFailing = automaticBackupProblem != nil
        environment.defaults.set(error.localizedDescription, forKey: "automaticBackupProblem")
        backupRevision += 1
        notice = Notice(text: String(localized: "The automatic backup failed: \(error.localizedDescription)"), isError: true)
        // One alert when backups start failing, not one per attempt.
        guard !alreadyFailing, !environment.isPreview else { return }
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Automatic backups stopped working")
        content.body = error.localizedDescription
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "backup-failed", content: content, trigger: nil))
        #endif
    }

    func noteAutomaticBackupWorked() {
        guard automaticBackupProblem != nil else { return }
        environment.defaults.removeObject(forKey: "automaticBackupProblem")
        backupRevision += 1
    }

    #if os(macOS)
    /// iCloud Drive on this Mac, where a backup folder keeps backups off the Mac too.
    public static var iCloudDriveFolder: URL? {
        let home = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
        let drive = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: drive.path) ? drive : nil
    }
    #endif
}
