import Foundation
import MailCore

/// Everything Margin keeps that isn't mail: restore it on a new Mac and carry on.
struct BackupContents: Codable {
    var created: Date
    var accounts: [MailAccount]
    var templates: [MailTemplate]
    var labels: [String: [String]]
    var snoozes: [String: Date]
    var outbox: [ScheduledMessage]
    var trustedPictureSenders: [String]
    /// Settings by their defaults key, as JSON values.
    var settings: [String: Data]
    /// Keychain items by key; only present in password-protected backups.
    var secrets: [String: String]?
    /// How the person writes, and their Ask chats.
    var writingProfile: WritingProfile?
    var askChats: [AskChat]?
}

/// Which parts of a backup to bring back.
public struct RestoreParts: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let mailboxes = RestoreParts(rawValue: 1 << 0)
    public static let settings = RestoreParts(rawValue: 1 << 1)
    public static let labelsAndSnoozes = RestoreParts(rawValue: 1 << 2)
    public static let templates = RestoreParts(rawValue: 1 << 3)
    public static let scheduled = RestoreParts(rawValue: 1 << 4)
    public static let writingAndChats = RestoreParts(rawValue: 1 << 5)
    public static let all: RestoreParts = [.mailboxes, .settings, .labelsAndSnoozes, .templates, .scheduled, .writingAndChats]
}

/// How often Margin saves a backup by itself.
public enum BackupSchedule: String, CaseIterable, Identifiable, Sendable {
    case off, daily, weekly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .daily: String(localized: "Every day")
        case .weekly: String(localized: "Every week")
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        }
    }
}

extension MailModel {
    /// Settings that travel with a backup.
    static let backedUpSettings = [
        "assistantSettings", "connectionSettings", "prefersPlainText", "textScale", "newMailAlerts", "undoSendDelay",
        "followUpDays", "appearance", "accentIndex", "appIcon", "appIconDark", "compactRows", "density", "layout", "singleKeyShortcuts", "keyOverrides",
        "insetPanel", "showsNextUp", "labelColors", "colorBlindSafe", "increaseContrast", "underlineLinks", "darkensMail", "reduceMotion",
        "learnsWriting", "suggestsReplies", "swipeLeading", "swipeTrailing", "backupSchedule",
        "writingInstructions", "holdSpaceDictates", "vipAddresses", "blocksTrackers", "hidesFromScreenSharing", "alertSound", "dropDownAlerts",
        "showsMenuBarItem", "showsDockBadge", "showsHoverActions", "showsAccountRail", "askPreferences", "remindsAboutAttachments", "reminderSound", "accountAlerts", "eventReminderMinutes", "emailGroups", "sortsNewMail", "showsAsChat",
        "offersTranslation", "aiOff", "quickProvider", "sortProvider", "sentFromMargin", "sentFromMarginText", "showsFormattingBar",
        "sharedSignatures",
    ]

    /// A backup file. Secrets (mail passwords, sign-ins, assistant keys) are included only
    /// when it's protected with a password.
    public func makeBackup(password: String?, includeSecrets: Bool) throws -> Data {
        try makeBackup(password: password, includeSecrets: includeSecrets, recoveryKey: backupRecoveryKey)
    }

    /// A backup file; with a recovery key, that key opens it too.
    func makeBackup(password: String?, includeSecrets: Bool, recoveryKey: String?) throws -> Data {
        var settings: [String: Data] = [:]
        for key in Self.backedUpSettings {
            guard let value = environment.defaults.object(forKey: key) else { continue }
            if let data = value as? Data {
                settings[key] = data
            } else if JSONSerialization.isValidJSONObject([value]) {
                settings[key] = try? JSONSerialization.data(withJSONObject: [value])
            }
        }
        var secrets: [String: String]?
        if includeSecrets, let password, !password.isEmpty {
            var found: [String: String] = [:]
            for account in accounts {
                for kind in ["password", "oauth", "token"] {
                    let key = "\(account.id.uuidString).\(kind)"
                    if let value = environment.keychain.read(key: key) { found[key] = value }
                }
            }
            for provider in AssistantProvider.allCases {
                if let value = environment.keychain.read(key: provider.keychainKey) { found[provider.keychainKey] = value }
            }
            secrets = found
        }
        let contents = BackupContents(
            created: Date(), accounts: accounts, templates: templates, labels: labelStore.labelsByThread, snoozes: snoozes,
            outbox: outbox, trustedPictureSenders: Array(trustedPictureSenders), settings: settings, secrets: secrets,
            writingProfile: writingProfile, askChats: askChats
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // The recovery key only joins a backup that has a password.
        let recovery = (password?.isEmpty == false) ? recoveryKey : nil
        return try BackupBox.seal(try encoder.encode(contents), password: password, recoveryKey: recovery)
    }

    /// Re-reads settings after a restore, so they apply without a restart.
    func applyStoredSettings() {
        let defaults = environment.defaults
        applySharedSignatures()
        if let data = defaults.data(forKey: "assistantSettings"), let value = try? JSONDecoder().decode(AssistantSettings.self, from: data) {
            assistantSettings = value
        }
        // Also follows the AI switch, which may have come back off.
        rebuildIntelligence()
        actionSettingsRevision += 1
        if let data = defaults.data(forKey: "connectionSettings"), let value = try? JSONDecoder().decode(ConnectionSettings.self, from: data) {
            connectionSettings = value
        }
        prefersPlainText = defaults.bool(forKey: "prefersPlainText")
        textScale = defaults.double(forKey: "textScale") == 0 ? 1 : defaults.double(forKey: "textScale")
        newMailAlerts = NewMailAlerts(rawValue: defaults.string(forKey: "newMailAlerts") ?? "") ?? .people
        undoSendDelay = defaults.object(forKey: "undoSendDelay") as? Int ?? 5
        followUpDays = defaults.object(forKey: "followUpDays") as? Int ?? 3
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        accentIndex = defaults.object(forKey: "accentIndex") as? Int ?? 0
        appIcon = AppIconChoice(rawValue: defaults.string(forKey: "appIcon") ?? "") ?? .blue
        appIconDark = defaults.bool(forKey: "appIconDark")
        compactRows = defaults.bool(forKey: "compactRows")
        density = Density(rawValue: defaults.string(forKey: "density") ?? "") ?? .roomy
        layout = ListLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .panels
        insetPanel = defaults.bool(forKey: "insetPanel")
        showsNextUp = defaults.object(forKey: "showsNextUp") as? Bool ?? true
        singleKeyShortcuts = defaults.object(forKey: "singleKeyShortcuts") as? Bool ?? true
        keyOverrides = defaults.dictionary(forKey: "keyOverrides") as? [String: String] ?? [:]
        colorBlindSafe = defaults.bool(forKey: "colorBlindSafe")
        increaseContrast = defaults.bool(forKey: "increaseContrast")
        underlineLinks = defaults.bool(forKey: "underlineLinks")
        darkensMail = defaults.object(forKey: "darkensMail") as? Bool ?? true
        offersTranslation = defaults.object(forKey: "offersTranslation") as? Bool ?? true
        reduceMotion = defaults.bool(forKey: "reduceMotion")
    }

    /// Merges a backup into what's here: nothing already set up is removed.
    @discardableResult
    public func restore(_ file: Data, password: String?, parts: RestoreParts = .all) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try decoder.decode(BackupContents.self, from: try BackupBox.open(file, password: password))
        restoreUndo = snapshotForRestore()
        var added: [MailAccount] = []
        if parts.contains(.mailboxes) {
            for (key, value) in contents.secrets ?? [:] { try? environment.keychain.save(value, key: key) }
            let known = Set(accounts.map(\.id))
            added = contents.accounts.filter { !known.contains($0.id) && $0.connection != .sample }
            accounts.removeAll { $0.connection == .sample && !added.isEmpty }
            accounts += added
            try? environment.accounts.save(accounts)
        }
        if parts.contains(.templates) {
            for template in contents.templates where !templates.contains(where: { $0.id == template.id }) { templates.append(template) }
            saveTemplates()
        }
        if parts.contains(.labelsAndSnoozes) {
            labelStore.merge(contents.labels)
            for (key, date) in contents.snoozes where snoozes[key] == nil { snoozes[key] = date }
            saveSnoozes()
            for sender in contents.trustedPictureSenders { trustedPictureSenders.insert(sender) }
            environment.defaults.set(Array(trustedPictureSenders).sorted(), forKey: "trustedPictureSenders")
        }
        if parts.contains(.scheduled) {
            for item in contents.outbox where !outbox.contains(where: { $0.id == item.id }) { outbox.append(item) }
            saveOutbox()
        }
        if parts.contains(.writingAndChats) {
            if let profile = contents.writingProfile, writingProfile.isEmpty {
                writingProfile = profile
                writingProfileLoaded = true
            }
            loadAskChatsIfNeeded()
            for chat in contents.askChats ?? [] where !askChats.contains(where: { $0.id == chat.id }) { askChats.append(chat) }
        }
        if parts.contains(.settings) {
            for (key, data) in contents.settings {
                if let wrapped = try? JSONSerialization.jsonObject(with: data) as? [Any], let value = wrapped.first {
                    environment.defaults.set(value, forKey: key)
                } else {
                    environment.defaults.set(data, forKey: key)
                }
            }
            applyStoredSettings()
        }
        Task { await reload() }
        if added.isEmpty { return String(localized: "Backup restored") }
        return added.count == 1
            ? String(localized: "Backup restored with 1 mailbox")
            : String(localized: "Backup restored with \(added.count) mailboxes")
    }

    // MARK: Automatic backups

    public var backupSchedule: BackupSchedule {
        get { BackupSchedule(rawValue: environment.defaults.string(forKey: "backupSchedule") ?? "") ?? .off }
        set { environment.defaults.set(newValue.rawValue, forKey: "backupSchedule"); backupRevision += 1 }
    }

    public var lastAutomaticBackup: Date? {
        _ = backupRevision
        return environment.defaults.object(forKey: "lastAutomaticBackup") as? Date
    }

    /// Where automatic backups go: a folder the person picked, or Margin's own Backups folder
    /// (on iPhone and iPad it shows in the Files app).
    public var backupFolder: URL {
        #if os(macOS)
        if let bookmark = environment.defaults.data(forKey: "backupFolderBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) { return url }
        }
        return environment.folder.appending(path: "Backups", directoryHint: .isDirectory)
        #else
        return (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? environment.folder)
            .appending(path: "Backups", directoryHint: .isDirectory)
        #endif
    }

    #if os(macOS)
    public func setBackupFolder(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            environment.defaults.set(bookmark, forKey: "backupFolderBookmark")
            backupRevision += 1
        }
    }
    #endif

    /// The password automatic backups are locked with, kept in the Keychain. With one, mail
    /// passwords and keys are included so a restore needs no signing in again.
    public func setAutomaticBackupPassword(_ password: String?) {
        if let password, !password.isEmpty {
            try? environment.keychain.save(password, key: "backupPassword")
        } else {
            environment.keychain.delete(key: "backupPassword")
        }
        backupRevision += 1
    }

    public var hasAutomaticBackupPassword: Bool {
        _ = backupRevision
        return environment.keychain.read(key: "backupPassword") != nil
    }

    /// Saves a backup when one is due, keeping the 30 newest. Called from the clock.
    func runAutomaticBackupIfDue(now: Date = Date()) {
        guard !environment.isPreview, let interval = backupSchedule.interval else { return }
        if let last = lastAutomaticBackup, now.timeIntervalSince(last) < interval { return }
        do {
            try writeAutomaticBackup(now: now)
            noteAutomaticBackupWorked()
        } catch {
            noteAutomaticBackupFailed(error)
        }
    }

    public func writeAutomaticBackup(now: Date = Date()) throws {
        let password = environment.keychain.read(key: "backupPassword")
        let data = try makeBackup(password: password, includeSecrets: password != nil)
        let folder = backupFolder
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        try data.write(to: folder.appending(path: "Margin Backup \(stamp).marginbackup"), options: .atomic)
        let backups = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == "marginbackup" && $0.lastPathComponent.hasPrefix("Margin Backup ") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for old in backups.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
        environment.defaults.set(now, forKey: "lastAutomaticBackup")
        backupRevision += 1
    }
}
