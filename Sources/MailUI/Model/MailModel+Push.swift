import Foundation
import MailCore

/// Instant notifications on iPhone and iPad (docs/push.md). On by default and optional: when iOS
/// gives the app a push token, every account whose provider can report new mail (Gmail,
/// Microsoft, JMAP) is subscribed through Margin's relay, and subscriptions renew on their own.
/// Turned off, the phone is deleted from the relay and mail is checked in the background, as
/// for accounts that can't report (plain IMAP).
extension MailModel {
    /// Whether this build has a relay at all; the setting only shows when it does.
    public var hasPushRelay: Bool { Self.pushRelay != nil }

    /// Instant notifications through Margin's relay.
    public var usesPushRelay: Bool {
        get { _ = alertRevision; return environment.defaults.object(forKey: "usesPushRelay") as? Bool ?? true }
        set {
            guard newValue != usesPushRelay else { return }
            environment.defaults.set(newValue, forKey: "usesPushRelay")
            alertRevision += 1
            Task {
                if newValue {
                    // Join again with the token iOS gave last time.
                    if let token = environment.defaults.data(forKey: "push.token") {
                        environment.defaults.removeObject(forKey: "push.token")
                        await registerForPush(token: token, sandbox: environment.defaults.bool(forKey: "push.sandbox"))
                    }
                } else {
                    await leavePushRelay()
                }
            }
        }
    }

    /// Stops the providers' reports where they allow it, deletes this phone (and so every
    /// subscription) from the relay, and forgets the relay's details here.
    func leavePushRelay() async {
        let states = pushStates
        for (key, state) in states {
            guard let account = accounts.first(where: { $0.id.uuidString == key }) else { continue }
            switch state.kind {
            case .graph:
                if let id = state.providerID, let token = try? await credentials.pushToken(for: account) {
                    try? await ProviderPush.deleteGraph(token: token, id: id)
                }
            case .gmail:
                if let token = try? await credentials.pushToken(for: account) { try? await ProviderPush.stopGmail(token: token) }
            case .jmap:
                break
            }
        }
        if let base = Self.pushRelay, let secret = pushSecret, let device = environment.keychain.read(key: "push.deviceID") {
            try? await PushRelay(base: base, secret: secret).forget(device: device)
        }
        environment.keychain.delete(key: "push.device")
        environment.keychain.delete(key: "push.deviceID")
        pushStates = [:]
    }

    struct PushState: Codable, Equatable {
        var kind: PushRelay.Kind
        var relayID: String
        var hook: URL
        var clientState: String?
        var providerID: String?
        var renewBy: Date
    }

    /// The relay built into this build; none turns instant notifications off.
    static var pushRelay: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "MarginPushRelayURL") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// The Pub/Sub topic Gmail reports to, `projects/<project>/topics/<topic>`.
    static var gmailTopic: String? {
        (Bundle.main.object(forInfoDictionaryKey: "MarginGmailPushTopic") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var pushStates: [String: PushState] {
        get { environment.defaults.data(forKey: "push.states").flatMap { try? JSONDecoder().decode([String: PushState].self, from: $0) } ?? [:] }
        set { environment.defaults.set(try? JSONEncoder().encode(newValue), forKey: "push.states") }
    }

    private var pushSecret: String? { environment.keychain.read(key: "push.device") }

    /// iOS handed over a push token: register this phone with the relay (again, if the token
    /// changed), then subscribe every account.
    public func registerForPush(token: Data, sandbox: Bool) async {
        // Kept even when the relay is off, so turning it back on can join again at once.
        environment.defaults.set(sandbox, forKey: "push.sandbox")
        guard let base = Self.pushRelay, usesPushRelay, !environment.isPreview else {
            if !usesPushRelay { environment.defaults.set(token, forKey: "push.token") }
            return
        }
        let known = environment.defaults.data(forKey: "push.token")
        if known != token || pushSecret == nil {
            do {
                let device = try await PushRelay(base: base).register(token: token, sandbox: sandbox, topic: Bundle.main.bundleIdentifier ?? "")
                try environment.keychain.save(device.secret, key: "push.device")
                try environment.keychain.save(device.device, key: "push.deviceID")
                environment.defaults.set(token, forKey: "push.token")
                // A new device on the relay starts without subscriptions.
                pushStates = [:]
            } catch {
                return
            }
        }
        await refreshPushSubscriptions()
    }

    /// Subscribes new accounts, renews ones about to lapse, and drops removed ones. Failures are
    /// quiet: that account keeps background checks until the next try.
    public func refreshPushSubscriptions(now: Date = Date()) async {
        guard let base = Self.pushRelay, usesPushRelay, let secret = pushSecret, !environment.isPreview else { return }
        let relay = PushRelay(base: base, secret: secret)
        var states = pushStates
        let live = accounts.filter { $0.connection != .sample }
        for key in states.keys where !live.contains(where: { $0.id.uuidString == key }) {
            if let state = states.removeValue(forKey: key) { try? await relay.unsubscribe(state.relayID) }
        }
        for account in live {
            guard let kind = pushKind(for: account) else { continue }
            let key = account.id.uuidString
            if let state = states[key], state.renewBy.timeIntervalSince(now) > 86_400 { continue }
            do {
                var state: PushState
                if let existing = states[key] {
                    state = existing
                } else {
                    let made = try await relay.subscribe(kind, account: key, address: kind == .gmail ? account.address.address : nil)
                    state = PushState(kind: kind, relayID: made.id, hook: made.url, clientState: made.clientState, renewBy: now)
                }
                switch kind {
                case .gmail:
                    guard let topic = Self.gmailTopic else { continue }
                    state.renewBy = try await ProviderPush.watchGmail(token: try await credentials.pushToken(for: account), topic: topic)
                case .graph:
                    let token = try await credentials.pushToken(for: account)
                    let until = now.addingTimeInterval(3 * 86_400)
                    if let id = state.providerID {
                        do { try await ProviderPush.renewGraph(token: token, id: id, until: until) } catch {
                            state.providerID = nil
                        }
                    }
                    if state.providerID == nil {
                        state.providerID = try await ProviderPush.subscribeGraph(token: token, hook: state.hook,
                                                                                clientState: state.clientState ?? "", until: until)
                    }
                    state.renewBy = until
                case .jmap:
                    guard let jmap = try provider(for: account) as? JMAPProvider else { continue }
                    if state.providerID == nil {
                        state.providerID = try await jmap.createPushSubscription(deviceClientID: key, url: state.hook)
                    }
                    state.renewBy = now.addingTimeInterval(30 * 86_400)
                }
                states[key] = state
            } catch {
                continue
            }
        }
        pushStates = states
    }

    /// A push arrived: finish a JMAP server's verification, or fetch new mail.
    public func handlePush(_ info: [AnyHashable: Any]) async {
        let margin = info["margin"] as? [String: Any] ?? [:]
        if let code = margin["verify"] as? String, let subscription = margin["subscription"] as? String {
            guard let (key, state) = pushStates.first(where: { $0.value.relayID == subscription }),
                  let id = state.providerID, let account = accounts.first(where: { $0.id.uuidString == key }),
                  let jmap = try? provider(for: account) as? JMAPProvider else { return }
            try? await jmap.verifyPush(id, code: code)
            return
        }
        await checkForNewMail()
    }

    /// How an account's provider reports new mail, if it can.
    func pushKind(for account: MailAccount) -> PushRelay.Kind? {
        switch (account.auth, account.connection) {
        case (.oauth(.google, _), _): Self.gmailTopic == nil ? nil : .gmail
        case (.oauth(.microsoft, _), _): .graph
        case (_, .jmap): .jmap
        default: nil
        }
    }
}
