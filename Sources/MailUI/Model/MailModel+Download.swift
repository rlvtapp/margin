import Foundation
import MailCore
import Network
#if canImport(UIKit)
import UIKit
#endif

/// How much of each folder's mail this device keeps, downloaded in the background. Set per
/// device (it isn't synced or restored): a Mac wants everything, a phone a recent stretch.
public enum KeepMail: String, CaseIterable, Sendable {
    case off, threeMonths, year, everything

    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .threeMonths: String(localized: "3 months")
        case .year: String(localized: "1 year")
        case .everything: String(localized: "Everything")
        }
    }

    /// Mail older than this isn't downloaded; nil for everything.
    func cutoff(now: Date) -> Date? {
        switch self {
        case .off: now
        case .threeMonths: Calendar.current.date(byAdding: .month, value: -3, to: now)
        case .year: Calendar.current.date(byAdding: .year, value: -1, to: now)
        case .everything: nil
        }
    }

    /// Whether a folder downloaded in full for `other` covers this stretch too.
    func isCovered(by other: String?) -> Bool {
        guard let other = other.flatMap(KeepMail.init(rawValue:)) else { return false }
        return Self.allCases.firstIndex(of: other)! >= Self.allCases.firstIndex(of: self)!
    }

    /// The Mac keeps everything; iPhone and iPad the last year.
    public static var deviceDefault: KeepMail {
        #if os(macOS)
        .everything
        #else
        .year
        #endif
    }
}

/// How far back the text of mail is saved ahead of time, so opening it doesn't wait on a
/// server. Set per device, like `KeepMail`.
public enum KeepText: String, CaseIterable, Sendable {
    case off, twoWeeks, threeMonths, year

    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .twoWeeks: String(localized: "2 weeks")
        case .threeMonths: String(localized: "3 months")
        case .year: String(localized: "1 year")
        }
    }

    /// Mail older than this keeps its text on the server until it's opened; nil when off.
    func cutoff(now: Date) -> Date? {
        switch self {
        case .off: nil
        case .twoWeeks: Calendar.current.date(byAdding: .day, value: -14, to: now)
        case .threeMonths: Calendar.current.date(byAdding: .month, value: -3, to: now)
        case .year: Calendar.current.date(byAdding: .year, value: -1, to: now)
        }
    }

    /// The Mac saves three months of text; iPhone and iPad two weeks.
    public static var deviceDefault: KeepText {
        #if os(macOS)
        .threeMonths
        #else
        .twoWeeks
        #endif
    }
}

/// What's saved on this device, as Settings shows it.
public struct SavedMailUsage: Equatable, Sendable {
    public var messages: Int
    public var bytes: Int
}

/// Whether the network may be used for the background download (iPhone and iPad: Wi-Fi or a
/// cable, not Low Data Mode), shared with the path monitor's own queue.
final class DownloadNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            self?.lock.withLock { self?.allowed = ok }
        }
        monitor.start(queue: DispatchQueue(label: "margin.download-network", qos: .utility))
    }

    var isAllowed: Bool { lock.withLock { allowed } }
    deinit { monitor.cancel() }
}

/// The quiet background download of older mail: per mailbox its inbox, then Sent and Archive,
/// page by page, headers only, into saved mail (never into memory). See docs/architecture.md,
/// "Older mail on this device".
extension MailModel {
    /// Messages asked for per page.
    nonisolated static let downloadPage = 200
    /// How often saved mail is compared with the server: a server that counts changes answers
    /// with only those, so that's cheap; one that doesn't is asked about every message.
    nonisolated static let checkWithChanges: TimeInterval = 3_600
    nonisolated static let checkWithoutChanges: TimeInterval = 86_400

    /// Starts the download, or carries on with it; it continues where it stopped, also after a
    /// quit. Stopped on iPhone and iPad when the app goes to the background.
    public func startDownloading() {
        guard downloadTask == nil else { return }
        #if os(iOS)
        if downloadNetwork == nil { downloadNetwork = DownloadNetwork() }
        #endif
        downloadTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let worked = await self.downloadStep()
                let pause = worked ? self.downloadPause : .seconds(60)
                try? await Task.sleep(for: pause)
            }
        }
    }

    public func stopDownloading() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloadingOlder = false
    }

    /// The folders downloaded for a mailbox, in order.
    func downloadFolders(_ id: UUID) -> [Mailbox] {
        var folders: [Mailbox] = []
        for role in [MailboxRole.inbox, .sent, .archive] {
            let found = role == .inbox ? mailboxes[id]?.first { $0.role == .inbox } : combinedMailbox(role, of: id)
            if let found, !folders.contains(where: { $0.id == found.id }) { folders.append(found) }
        }
        return folders
    }

    /// Whether downloading may go on now. iPhone and iPad: Wi-Fi, not Low Data Mode, not Low
    /// Power Mode, and charging or above 20 percent.
    func mayDownload() -> Bool {
        guard keepMail != .off || keepText != .off else { return false }
        #if os(iOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if downloadNetwork?.isAllowed == false { return false }
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let charging = device.batteryState == .charging || device.batteryState == .full
        if !charging, device.batteryLevel >= 0, device.batteryLevel < 0.2 { return false }
        #endif
        return true
    }

    /// One page of one folder, or one comparison with the server. Returns whether anything was
    /// done (then the next comes after a short pause; otherwise after a minute).
    func downloadStep(now: Date = Date()) async -> Bool {
        guard mayDownload() else {
            isDownloadingOlder = false
            return false
        }
        let cache = environment.cache
        // The text of recent mail comes first: it's what makes opening a mail instant.
        if await downloadTexts(now: now) { return true }
        let keep = keepMail
        guard keep != .off else {
            if isDownloadingOlder { isDownloadingOlder = false }
            return false
        }
        let cutoff = keep.cutoff(now: now)
        // A page of the first folder not downloaded yet.
        for account in accounts {
            guard let provider = try? provider(for: account) else { continue }
            for mailbox in downloadFolders(account.id) {
                var progress = await cache.downloadProgress(account: account.id, mailbox: mailbox.id) ?? .init()
                guard !keep.isCovered(by: progress.done) else { continue }
                if !isDownloadingOlder { isDownloadingOlder = true }
                do {
                    let page = try await provider.olderMessages(in: mailbox, after: progress.position, limit: Self.downloadPage)
                    if let validity = page.validity, let old = progress.validity, validity != old {
                        // The folder's ids were renumbered: start it again from the newest.
                        progress = .init(validity: validity)
                        await cache.saveDownloadProgress(progress, account: account.id, mailbox: mailbox.id)
                        return true
                    }
                    progress.validity = page.validity
                    let kept = cutoff.map { cutoff in page.messages.filter { $0.date >= cutoff } } ?? page.messages
                    if !kept.isEmpty {
                        await cache.addThreads(kept.map { MailThread(id: $0.id, messages: [$0]) }, account: account.id, mailbox: mailbox.id)
                    }
                    progress.position = page.next
                    if page.next == nil || kept.count < page.messages.count {
                        progress.done = keep.rawValue
                        progress.position = nil
                    }
                    await cache.saveDownloadProgress(progress, account: account.id, mailbox: mailbox.id)
                    downloadedPages += 1
                    if downloadedPages % 25 == 0 { await refreshSavedMailUsage() }
                    return true
                } catch MailError.notSupported {
                    progress.done = KeepMail.everything.rawValue
                    await cache.saveDownloadProgress(progress, account: account.id, mailbox: mailbox.id)
                } catch {
                    // Offline or the server said no: this mailbox waits, the others go on.
                    break
                }
            }
        }
        if isDownloadingOlder {
            isDownloadingOlder = false
            await refreshSavedMailUsage()
        }
        // Everything is here: keep it honest.
        for account in accounts {
            guard let provider = try? provider(for: account) else { continue }
            for mailbox in downloadFolders(account.id) {
                guard var progress = await cache.downloadProgress(account: account.id, mailbox: mailbox.id) else { continue }
                let every = progress.token == nil ? Self.checkWithoutChanges : Self.checkWithChanges
                if let checked = progress.checked, now.timeIntervalSince(checked) < every { continue }
                let ids = await cache.savedIDs(account: account.id, mailbox: mailbox.id)
                guard let check = try? await provider.checkSaved(ids, in: mailbox, since: progress.token) else { break }
                await cache.apply(check, account: account.id, mailbox: mailbox.id)
                progress.checked = now
                progress.token = check.token
                await cache.saveDownloadProgress(progress, account: account.id, mailbox: mailbox.id)
                return true
            }
        }
        return false
    }

    /// Messages whose text is asked for at once.
    nonisolated static let textBatch = 8
    /// How often the walk starts again from the newest, for mail that came in since.
    nonisolated static let textWalkAgain: TimeInterval = 900

    /// One batch of texts for the first mailbox that still has recent mail without one, newest
    /// first. Each mailbox is walked once from the newest down to the stretch's start (messages
    /// the server wouldn't give are passed over, not asked for again and again), and again
    /// every quarter of an hour for what came in since. Returns whether anything was asked.
    func downloadTexts(now: Date) async -> Bool {
        guard let since = keepText.cutoff(now: now) else { return false }
        let cache = environment.cache
        if let started = textWalkStarted, now.timeIntervalSince(started) >= Self.textWalkAgain { textWalked = [:] }
        if textWalked.isEmpty { textWalkStarted = now }
        for account in accounts {
            guard let provider = try? provider(for: account) else { continue }
            let batch = await cache.messagesWithoutText(account: account.id, since: since, before: textWalked[account.id], limit: Self.textBatch)
            guard let oldest = batch.last else { continue }
            // Mail already in memory with its text (just opened or read ahead) is only saved.
            guard let fetched = try? await provider.readableBodies(of: batch) else { continue }
            for message in batch {
                guard let body = fetched[message.id] else { continue }
                await cache.saveBody(body, of: message, account: account.id)
            }
            textWalked[account.id] = oldest.date
            downloadedTexts += fetched.count
            return true
        }
        return false
    }

    public func refreshSavedMailUsage() async {
        let usage = await environment.cache.usage()
        let new = SavedMailUsage(messages: usage.messages, bytes: usage.bytes)
        if savedMailUsage != new { savedMailUsage = new }
    }

    /// Takes the older mail downloaded in the background out again. It downloads again unless
    /// Keep on this device is Off.
    public func clearDownloadedMail() async {
        let wasRunning = downloadTask != nil
        stopDownloading()
        await environment.cache.clearDownloaded()
        await refreshSavedMailUsage()
        if wasRunning { startDownloading() }
    }
}
