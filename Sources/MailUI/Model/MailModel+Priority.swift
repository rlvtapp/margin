import Foundation
import MailCore

/// Pinned conversations stay at the top of the inbox; VIPs are the people whose mail matters
/// most, with their own mailbox and an alert setting of their own.
extension MailModel {
    // MARK: Pins

    private var pinsFile: JSONFile<Set<String>> { JSONFile(url: environment.folder.appending(path: "pins.json")) }

    var pinnedKeys: Set<String> {
        get {
            _ = priorityRevision
            if let pinStore { return pinStore }
            let loaded = environment.isPreview ? [] : (pinsFile.load() ?? [])
            pinStore = loaded
            return loaded
        }
        set {
            pinStore = newValue
            priorityRevision += 1
            if !environment.isPreview { pinsFile.save(newValue) }
        }
    }

    public func isPinned(_ thread: MailThread) -> Bool { pinnedKeys.contains(LabelStore.key(for: thread)) }

    public func togglePin(_ thread: MailThread) {
        let key = LabelStore.key(for: thread)
        if pinnedKeys.contains(key) { pinnedKeys.remove(key) } else { pinnedKeys.insert(key) }
    }

    /// Pins the open or selected conversations, or unpins them when they're all pinned.
    public func togglePinOnSelection() {
        let targets = actionTargets
        guard !targets.isEmpty else { return }
        let pin = !targets.allSatisfy(isPinned)
        for thread in targets {
            let key = LabelStore.key(for: thread)
            if pin { pinnedKeys.insert(key) } else { pinnedKeys.remove(key) }
        }
    }

    /// Pinned conversations first, each part keeping its order.
    func pinnedFirst(_ threads: [MailThread]) -> [MailThread] {
        let pins = pinnedKeys
        guard !pins.isEmpty else { return threads }
        let pinned = threads.filter { pins.contains(LabelStore.key(for: $0)) }
        guard !pinned.isEmpty else { return threads }
        return pinned + threads.filter { !pins.contains(LabelStore.key(for: $0)) }
    }

    // MARK: VIPs

    /// Addresses of VIPs, lowercased.
    public var vipAddresses: Set<String> {
        get { _ = priorityRevision; return Set(environment.defaults.stringArray(forKey: "vipAddresses") ?? []) }
        set { environment.defaults.set(newValue.sorted(), forKey: "vipAddresses"); priorityRevision += 1 }
    }

    public func isVIP(_ address: EmailAddress) -> Bool { vipAddresses.contains(address.address.lowercased()) }

    public func toggleVIP(_ address: EmailAddress) {
        let key = address.address.lowercased()
        if vipAddresses.contains(key) { vipAddresses.remove(key) } else { vipAddresses.insert(key) }
        notice = Notice(text: isVIP(address) ? String(localized: "\(address.displayName) is a VIP") : String(localized: "\(address.displayName) is no longer a VIP"))
    }

    /// Conversations in the inbox from a VIP.
    func vipThreads(_ accountID: UUID?) -> [MailThread] {
        let vips = vipAddresses
        guard !vips.isEmpty else { return [] }
        return allInboxesThreads(accountID).filter { thread in thread.messages.contains { vips.contains($0.from.address.lowercased()) } }
    }
}

extension MailModel {
    /// Removes tracking pixels and untracks links in every message, even after pictures are loaded.
    public var blocksTrackers: Bool {
        get { _ = priorityRevision; return environment.defaults.object(forKey: "blocksTrackers") as? Bool ?? true }
        set {
            environment.defaults.set(newValue, forKey: "blocksTrackers")
            SafeHTMLCache.blocksTrackers = newValue
            priorityRevision += 1
        }
    }
}
