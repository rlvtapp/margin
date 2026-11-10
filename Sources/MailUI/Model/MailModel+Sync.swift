import Foundation
import MailCore

/// Sync with iCloud: mailboxes, settings, templates, workspaces, labels and sorting through Margin's folder in
/// iCloud Drive, passwords and sign-ins through iCloud Keychain. On by default; where iCloud
/// isn't available (signed out, or a build without a container) everything stays on the device.
extension MailModel {
    /// Settings that stay with each device.
    static let deviceOnlySettings: Set<String> = ["backupSchedule"]

    public var syncsWithICloud: Bool {
        get { _ = contactSettingsRevision; return environment.defaults.object(forKey: "syncsWithICloud") as? Bool ?? true }
        set {
            environment.defaults.set(newValue, forKey: "syncsWithICloud")
            // The Keychain reads this from the standard defaults, the same in every part of the app.
            UserDefaults.standard.set(newValue, forKey: Keychain.syncKey)
            environment.keychain.resave(keys: secretKeys)
            contactSettingsRevision += 1
            if newValue { Task { await syncNow() } } else { syncProblem = nil }
        }
    }

    /// Tells the Keychain whether to sync, and the first time, moves secrets saved before into
    /// iCloud Keychain. Runs at launch.
    func prepareSync() {
        let on = syncsWithICloud
        UserDefaults.standard.set(on, forKey: Keychain.syncKey)
        if on && !environment.defaults.bool(forKey: "syncMovedSecrets") {
            environment.keychain.resave(keys: secretKeys)
            environment.defaults.set(true, forKey: "syncMovedSecrets")
        }
    }

    /// Every secret Margin keeps, so they can move into or out of iCloud Keychain.
    var secretKeys: [String] {
        accounts.flatMap { account in ["password", "oauth", "token", "api"].map { "\(account.id.uuidString).\($0)" } }
            + AssistantProvider.allCases.map(\.keychainKey)
            + cardDAVBooks.map(\.keychainKey)
    }

    /// Merges this device with iCloud Drive and applies what changed elsewhere.
    public func syncNow() async {
        guard syncsWithICloud, !environment.isPreview, !isSyncing else { return }
        guard let folder = CloudSync.folder() else {
            syncProblem = CloudSync.unavailableReason
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        syncProblem = nil

        let real = accounts.filter { $0.connection != .sample }
        let syncedAccounts = sync("mailboxes", in: folder, current: keyed(real, by: \.id.uuidString))
        applySynced(accounts: syncedAccounts.values.compactMap { CloudSync.decode(MailAccount.self, from: $0) })

        let syncedTemplates = sync("templates", in: folder, current: keyed(templates, by: \.id.uuidString))
        let newTemplates = order(syncedTemplates.values.compactMap { CloudSync.decode(MailTemplate.self, from: $0) }, like: templates)
        if newTemplates != templates { templates = newTemplates; saveTemplates() }

        let syncedWorkspaces = sync("workspaces", in: folder, current: keyed(workspaces, by: \.id.uuidString))
        let newWorkspaces = order(syncedWorkspaces.values.compactMap { CloudSync.decode(Workspace.self, from: $0) }, like: workspaces)
        if newWorkspaces != workspaces { workspaces = newWorkspaces }

        // Labels, which is where sorting puts conversations, and what sorting already looked at,
        // so a Mac and an iPhone share the work instead of each doing it all.
        let labels = keyed(labelStore.labelsByThread)
        let syncedLabels = sync("labels", in: folder, current: labels)
        if syncedLabels != labels { labelStore.replaceAll(with: syncedLabels.compactMapValues { CloudSync.decode([String].self, from: $0) }) }
        let checked = keyed(sortingChecked)
        let syncedChecked = sync("sorting", in: folder, current: checked)
        if syncedChecked != checked { sortingChecked = syncedChecked.compactMapValues { CloudSync.decode(String.self, from: $0) } }

        var settings: [String: Data] = [:]
        for key in Self.backedUpSettings where !Self.deviceOnlySettings.contains(key) {
            if let data = Self.encodeSetting(environment.defaults.object(forKey: key)) { settings[key] = data }
        }
        let syncedSettings = sync("settings", in: folder, current: settings)
        if syncedSettings != settings {
            for key in Set(settings.keys).union(syncedSettings.keys) where syncedSettings[key] != settings[key] {
                if let data = syncedSettings[key] { Self.applySetting(data, key: key, to: environment.defaults) } else { environment.defaults.removeObject(forKey: key) }
            }
            applyStoredSettings()
        }
        lastSync = Date()
    }

    /// One file: merge, write back, remember what was synced, and return the merged items.
    private func sync(_ name: String, in folder: URL, current: [String: Data]) -> [String: Data] {
        let memoryKey = "sync.\(name)"
        let last = environment.defaults.dictionary(forKey: memoryKey) as? [String: Data] ?? [:]
        let remote = CloudSync.read(name, in: folder)
        let merged = CloudSync.merge(current: current, lastSynced: last, remote: remote)
        if merged.remote != remote { CloudSync.write(merged.remote, name: name, in: folder) }
        environment.defaults.set(merged.items, forKey: memoryKey)
        return merged.items
    }

    private func keyed<T: Encodable>(_ values: [String: T]) -> [String: Data] {
        values.compactMapValues { CloudSync.encode($0) }
    }

    private func keyed<T: Encodable>(_ items: [T], by key: (T) -> String) -> [String: Data] {
        var result: [String: Data] = [:]
        for item in items { if let data = CloudSync.encode(item) { result[key(item)] = data } }
        return result
    }

    /// Keeps the local order; items new to this device go at the end.
    private func order<T: Identifiable>(_ items: [T], like current: [T]) -> [T] where T.ID == UUID {
        let position = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($1.id, $0) })
        return items.sorted { (position[$0.id] ?? Int.max, $0.id.uuidString) < (position[$1.id] ?? Int.max, $1.id.uuidString) }
    }

    /// Mailboxes added, changed or removed on another device. Their passwords arrive through
    /// iCloud Keychain.
    private func applySynced(accounts synced: [MailAccount]) {
        let real = accounts.filter { $0.connection != .sample }
        guard synced != real else { return }
        let incoming = Dictionary(uniqueKeysWithValues: synced.map { ($0.id, $0) })
        for gone in real where incoming[gone.id] == nil {
            providers.removeValue(forKey: gone.id).map { provider in Task { await provider.disconnect() } }
            accounts.removeAll { $0.id == gone.id }
            mailboxes[gone.id] = nil
            inboxes[gone.id] = nil
        }
        for account in synced.sorted(by: { $0.label < $1.label }) {
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                guard accounts[index] != account else { continue }
                accounts[index] = account
                providers.removeValue(forKey: account.id)
            } else {
                accounts.append(account)
            }
        }
        if accounts.contains(where: { $0.connection != .sample }) { accounts.removeAll { $0.connection == .sample } }
        if accounts.isEmpty { accounts = [.sample, .samplePersonal] }
        try? environment.accounts.save(accounts)
        Task { await reload() }
    }

    /// A setting as bytes, the same way a backup stores it.
    static func encodeSetting(_ value: Any?) -> Data? {
        guard let value else { return nil }
        if let data = value as? Data { return data }
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
    }

    static func applySetting(_ data: Data, key: String, to defaults: UserDefaults) {
        if let wrapped = try? JSONSerialization.jsonObject(with: data) as? [Any], let value = wrapped.first {
            defaults.set(value, forKey: key)
        } else {
            defaults.set(data, forKey: key)
        }
    }
}
