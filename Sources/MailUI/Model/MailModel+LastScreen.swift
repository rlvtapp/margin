import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The window as it was when Margin last ran, so the next launch opens on it at once.
///
/// Saved mail in the database fills the window too, but only after the window is up: `start()`
/// runs after the first frame, and reading every inbox's newest page took 160 ms on a warm launch
/// and 1.9 s on a cold one. Meanwhile the sidebar had no folders and the open mail said
/// "Loading…". This file (every mailbox's folders, the newest page of each inbox and of Sent, the
/// open conversation with its texts) is read while the model is made, before the first frame. Saved mail and the servers then replace it as usual.
extension MailModel {
    struct LastScreen: Codable {
        static let currentVersion = 1
        var version = LastScreen.currentVersion
        var mailboxes: [Saved]
        var selected: String?
        /// Texts of the open conversation, by `bodyKey`.
        var bodies: [String: MessageBody]

        struct Saved: Codable {
            var account: UUID
            var folders: [Mailbox]
            var threads: [SavedThread]
            /// Sent mail, for your replies in conversations and Home's count (without texts).
            var sent: [MailMessage]
        }

        struct SavedThread: Codable {
            var id: String
            var messages: [MailMessage]
        }
    }

    /// How many conversations of each inbox go in: the same page saved mail loads at launch,
    /// so unread counts and the list are the same before and after it's read. With fewer, the
    /// counts climbed a moment after opening.
    static let lastScreenThreads = MailModel.listPage

    var lastScreenFile: URL { environment.folder.appending(path: "last-screen.json") }

    /// Puts the last screen back. Called from `init`, before anything is drawn.
    func restoreLastScreen() {
        guard !environment.isPreview, let data = try? Data(contentsOf: lastScreenFile),
              let screen = try? JSONDecoder().decode(LastScreen.self, from: data),
              screen.version == LastScreen.currentVersion else { return }
        let known = Set(accounts.map(\.id))
        for saved in screen.mailboxes where known.contains(saved.account) {
            mailboxes[saved.account] = saved.folders
            restoredFromLastScreen.insert(saved.account)
            shelves[saved.account] = InboxShelf(saved.threads.map { thread in
                let messages = thread.messages.map { message in
                    var compact = message
                    compact.listHeaders = InboxSplit.compact(message.listHeaders)
                    compact.snippet = HTMLText.cleanedPreview(message.snippet)
                    return compact
                }
                return Self.tag(MailThread(id: thread.id, messages: messages), account: saved.account)
            })
            if !saved.sent.isEmpty {
                sentMail[saved.account] = saved.sent
                sentFromLastScreen.insert(saved.account)
            }
        }
        for (key, body) in screen.bodies where known.contains(where: { key.hasPrefix($0.uuidString) }) {
            bodies[key] = body
        }
        if !shelves.isEmpty { inboxesChanged(order: true) }
        if let selected = screen.selected, shelves.values.contains(where: { $0.threads.contains { $0.id == selected } }) {
            selectedThreadID = selected
        }
        // The open mail's pages, started now so they're drawn by the time the window is.
        let pages = screen.bodies.values.filter { $0.html != nil }.count
        if pages > 0 { MailWebViewPool.warmUp(count: pages, background: HTMLMessageView.lightGround) }
    }

    /// Saves the screen as it is, a second after the last change asked for it, on the side.
    func saveLastScreen() {
        guard !environment.isPreview else { return }
        lastScreenSaving?.cancel()
        lastScreenSaving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, let screen = self.lastScreen() else { return }
            let file = self.lastScreenFile
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(screen) else { return }
                try? data.write(to: file, options: .atomic)
            }.value
        }
    }

    /// Writes the screen at once, as it is: for quitting and going to the background. The
    /// open mail is saved this way rather than on every mail opened, which wrote 600 KB each
    /// time and churned memory.
    func saveLastScreenNow() {
        guard !environment.isPreview, let screen = lastScreen(), let data = try? JSONEncoder().encode(screen) else { return }
        lastScreenSaving?.cancel()
        try? data.write(to: lastScreenFile, options: .atomic)
    }

    func saveLastScreenWhenLeaving() {
        #if os(macOS)
        let names = [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification]
        #else
        let names = [UIApplication.didEnterBackgroundNotification]
        #endif
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveLastScreenNow() }
            }
        }
    }

    func lastScreen() -> LastScreen? {
        guard !accounts.isEmpty else { return nil }
        let open = selectedThread
        var saved: [LastScreen.Saved] = []
        for account in accounts {
            guard let folders = mailboxes[account.id], let shelf = shelves[account.id] else { continue }
            var threads = Array(shelf.threads.prefix(Self.lastScreenThreads))
            if let open, open.accountID == account.id, !threads.contains(where: { $0.id == open.id }) { threads.append(open) }
            // All of the Sent mail in memory (without texts), not only the replies in the open
            // conversation: Home's count of what needs you reads it, and with only a few it
            // counted answered conversations for a moment (a 2 on Home that went away).
            var sent = (sentMail[account.id] ?? []).sorted { $0.date > $1.date }.prefix(Self.lastScreenThreads).map(Self.withoutText)
            if let open, open.accountID == account.id {
                let own = Set(open.messages.map(\.id)), kept = Set(sent.map(\.id))
                sent += conversation(open).messages.filter { !own.contains($0.id) && !kept.contains($0.id) }.map(Self.withoutText)
            }
            saved.append(LastScreen.Saved(account: account.id, folders: folders,
                                          threads: threads.map { LastScreen.SavedThread(id: Self.untagged($0).id, messages: $0.messages.map(Self.withoutText)) },
                                          sent: sent))
        }
        var texts: [String: MessageBody] = [:]
        if let open {
            for message in conversation(open).messages {
                let key = Self.bodyKey(open.accountID, message.id)
                if let body = bodies[key] ?? message.body { texts[key] = Self.withoutBigFiles(body) }
            }
        }
        return LastScreen(mailboxes: saved, selected: open?.id, bodies: texts)
    }

    /// A list row's message: its text is kept apart, in `bodies`.
    nonisolated static func withoutText(_ message: MailMessage) -> MailMessage {
        var copy = message
        copy.body = nil
        return copy
    }

    /// A text without the contents of big files (they're fetched when opened), like saved mail.
    nonisolated static func withoutBigFiles(_ body: MessageBody) -> MessageBody {
        var copy = body
        copy.attachments = copy.attachments.map { attachment in
            var small = attachment
            if (small.data?.count ?? 0) > 256 * 1024 { small.data = nil }
            return small
        }
        return copy
    }
}
