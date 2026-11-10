#if os(iOS) && canImport(WatchConnectivity)
import Foundation
import MailCore
import WatchConnectivity

/// Keeps Margin on Apple Watch up to date: after every check for mail the inbox goes over,
/// and what's tapped on the watch (Done, Star, Read, a short reply) comes back here.
/// The watch can't reach mail servers itself, so the iPhone does the mail work.
@MainActor
public final class WatchBridge: NSObject {
    public static let shared = WatchBridge()
    weak var model: MailModel?

    /// Same shape as the watch's `WatchMail`.
    struct Mail: Codable {
        var id: String
        var sender: String
        var subject: String
        var preview: String
        var body: String
        var formatted: String?
        var date: Date
        var isUnread: Bool
        var isStarred: Bool
        var code: String?
        var replies: [String]
        var color: Int
    }

    public func attach(to model: MailModel) {
        guard WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the newest 40 inbox conversations; the watch keeps the latest it got.
    func push() {
        guard let model, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        let mails = model.inboxThreads(nil).filter { !model.isSnoozed($0) }.prefix(40).map { thread in
            Mail(
                id: thread.id,
                sender: thread.latest.from.displayName,
                subject: thread.subject,
                preview: thread.latest.snippet,
                body: String((model.body(of: thread.latest, in: thread)?.text ?? thread.latest.snippet).prefix(2_000)),
                // The watch has no web view: HTML mail goes over as light formatting instead.
                formatted: model.body(of: thread.latest, in: thread)?.html.map { String(HTMLText.markdown($0).prefix(3_000)) },
                date: thread.date,
                isUnread: thread.isUnread,
                isStarred: thread.isStarred,
                code: model.signInCode(in: thread),
                replies: model.replySuggestions[thread.id] ?? [],
                color: model.account(thread.accountID)?.colorIndex ?? 0
            )
        }
        guard let data = try? JSONEncoder().encode(Array(mails)) else { return }
        try? WCSession.default.updateApplicationContext(["mails": data, "updated": Date()])
    }

    fileprivate func handle(_ message: WatchMessage) {
        guard let model, let thread = SiriBridgeThreads.find(message.id, in: model) else { return }
        switch message.action {
        case "done": Task { await model.apply(.done, to: [thread], announce: false) }
        case "trash": Task { await model.apply(.trash, to: [thread], announce: false) }
        case "star": Task { await model.apply(thread.isStarred ? .unstar : .star, to: [thread], announce: false) }
        case "read": Task { await model.apply(.markRead, to: [thread], announce: false) }
        case "reply":
            guard let text = message.text, !text.isEmpty, let account = model.account(thread.accountID) else { return }
            var state = ComposeState(account: account, draft: Draft.reply(to: thread, from: account.replyAddress(for: thread)), isReply: true)
            state.draft.text = text + state.draft.text
            Task { _ = await model.send(state) }
        default: break
        }
    }
}

/// A watch tap, out of the untyped dictionary before it crosses threads.
struct WatchMessage: Sendable {
    var action: String
    var id: String
    var text: String?

    nonisolated init?(_ dictionary: [String: Any]) {
        guard let action = dictionary["action"] as? String, let id = dictionary["id"] as? String else { return nil }
        self.action = action
        self.id = id
        text = dictionary["text"] as? String
    }
}

enum SiriBridgeThreads {
    @MainActor static func find(_ id: String, in model: MailModel) -> MailThread? {
        (model.inboxThreads(nil) + model.folder).first { $0.id == id }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push() }
    }

    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let parsed = WatchMessage(message) else { return }
        Task { @MainActor in self.handle(parsed) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let parsed = WatchMessage(userInfo) else { return }
        Task { @MainActor in self.handle(parsed) }
    }
}
#endif
