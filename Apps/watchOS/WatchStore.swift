import Foundation
import Observation
import WatchConnectivity

/// One conversation as the watch knows it: what the iPhone sent over.
struct WatchMail: Identifiable, Hashable, Codable {
    var id: String
    var sender: String
    var subject: String
    var preview: String
    var body: String
    /// HTML mail as light Markdown: bold, bullets and links.
    var formatted: String?
    var date: Date
    var isUnread: Bool
    var isStarred: Bool
    var code: String?
    var replies: [String]
    var color: Int
}

/// The inbox the iPhone keeps up to date, and the way actions go back to it.
@Observable
@MainActor
final class WatchStore: NSObject {
    private(set) var mails: [WatchMail] = []
    private(set) var updated: Date?
    private(set) var isReachable = false
    private var session: WCSession? { WCSession.isSupported() ? .default : nil }

    func start() {
        if ProcessInfo.processInfo.arguments.contains("-sample-mail") || session == nil {
            mails = Self.sample
            updated = Date()
            return
        }
        session?.delegate = self
        session?.activate()
        if let saved = UserDefaults.standard.data(forKey: "mails"), let decoded = try? JSONDecoder().decode([WatchMail].self, from: saved) {
            mails = decoded
        }
    }

    /// Done, star, read: changed here at once, then on the iPhone.
    func perform(_ action: String, on mail: WatchMail) {
        switch action {
        case "done", "trash": mails.removeAll { $0.id == mail.id }
        case "star": update(mail.id) { $0.isStarred.toggle() }
        case "read": update(mail.id) { $0.isUnread = false }
        default: break
        }
        send(["action": action, "id": mail.id])
    }

    /// Sends a short reply through the iPhone, from the address the mail came to.
    func reply(_ text: String, to mail: WatchMail) {
        send(["action": "reply", "id": mail.id, "text": text])
        update(mail.id) { $0.isUnread = false }
    }

    private func update(_ id: String, _ change: (inout WatchMail) -> Void) {
        guard let index = mails.firstIndex(where: { $0.id == id }) else { return }
        change(&mails[index])
    }

    private func send(_ message: [String: Any]) {
        guard let session, session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil)
        } else {
            // Delivered when the iPhone app next wakes.
            session.transferUserInfo(message)
        }
    }

    fileprivate func apply(_ payload: Payload) {
        guard let data = payload.mails,
              let decoded = try? JSONDecoder().decode([WatchMail].self, from: data) else { return }
        mails = decoded
        updated = payload.updated ?? Date()
        UserDefaults.standard.set(data, forKey: "mails")
    }

    static let sample: [WatchMail] = [
        WatchMail(id: "1", sender: "Kettle", subject: "Your Kettle sign-in code", preview: "Use 482 913 to sign in.",
                  body: "Use 482 913 to sign in to Kettle. The code expires in 10 minutes.", formatted: nil, date: Date().addingTimeInterval(-120),
                  isUnread: true, isStarred: false, code: "482913", replies: [], color: 3),
        WatchMail(id: "2", sender: "Noor Haddad", subject: "Lisbon in May?", preview: "Booked. Sending the confirmation in a minute.",
                  body: "Booked. Sending the confirmation in a minute. Also: we're going to that tile museum, no arguments.",
                  date: Date().addingTimeInterval(-600), isUnread: true, isStarred: false, code: nil,
                  replies: ["Can't wait!", "Museum it is", "Thanks, Noor"], color: 1),
        WatchMail(id: "3", sender: "Maya Lindqvist", subject: "Launch plan for March", preview: "Good catch. Sam said he'd take the FAQ.",
                  body: "Good catch. Sam said he'd take the FAQ, I've added it to the plan for the 8th.", formatted: nil, date: Date().addingTimeInterval(-3600),
                  isUnread: true, isStarred: true, code: nil, replies: ["Sounds good", "Thanks Maya"], color: 4),
        WatchMail(id: "4", sender: "Mum", subject: "Sunday lunch", preview: "Are you coming on Sunday?",
                  body: "Are you coming on Sunday? Your aunt is bringing the dog.", formatted: nil, date: Date().addingTimeInterval(-9000),
                  isUnread: false, isStarred: false, code: nil, replies: ["Yes, see you then", "Can't this time"], color: 2),
        WatchMail(id: "5", sender: "The Slow Cook", subject: "Five soups for cold evenings", preview: "A lentil soup that takes ten minutes.",
                  body: "A lentil soup that takes ten minutes, and four that are worth the wait.",
                  formatted: "**Five soups for cold evenings**\n\nA **lentil soup** that takes ten minutes, and four that are worth the wait.\n\n• Red lentil\n• Leek and potato\n• Roasted tomato\n\n[Read the recipes](https://slowcook.example/soups)",
                  date: Date().addingTimeInterval(-86_000), isUnread: true, isStarred: false, code: nil, replies: [], color: 1),
    ]
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let payload = Payload(session.receivedApplicationContext)
        Task { @MainActor in
            self.isReachable = reachable
            self.apply(payload)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let payload = Payload(context)
        Task { @MainActor in self.apply(payload) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }
}

/// What the iPhone sends, taken out of the untyped dictionary before it crosses threads.
struct Payload: Sendable {
    var mails: Data?
    var updated: Date?

    nonisolated init(_ context: [String: Any]) {
        mails = context["mails"] as? Data
        updated = context["updated"] as? Date
    }
}
