import Foundation
import MailCore
#if canImport(AppKit)
import AppKit
#endif

/// The sound new mail makes. On the Mac, any of the system's alert sounds; on iPhone and
/// iPad, the system sound or none.
public struct AlertSound: Hashable, Sendable, Identifiable {
    public var name: String
    public var id: String { name }
    public static let standard = AlertSound(name: "default")
    public static let none = AlertSound(name: "none")

    public var title: String {
        switch name {
        case "default": String(localized: "Margin")
        case "none": String(localized: "None")
        default: name
        }
    }

    /// Every choice on this device.
    public static var choices: [AlertSound] {
        #if os(macOS)
        let system = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = system.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
        return [.standard] + names.map(AlertSound.init(name:)) + [.none]
        #else
        return [.standard, .none]
        #endif
    }
}

extension MailModel {
    /// The sound for new mail.
    public var alertSound: AlertSound {
        get { _ = alertRevision; return AlertSound(name: environment.defaults.string(forKey: "alertSound") ?? "default") }
        set { environment.defaults.set(newValue.name, forKey: "alertSound"); alertRevision += 1; playAlertSound(newValue) }
    }

    /// On the Mac: new mail slides down from the top of the screen, with Reply and Dismiss.
    public var showsDropDownAlerts: Bool {
        get { _ = alertRevision; return environment.defaults.object(forKey: "dropDownAlerts") as? Bool ?? true }
        set { environment.defaults.set(newValue, forKey: "dropDownAlerts"); alertRevision += 1 }
    }

    /// A mailbox's own alert setting; nil follows the main one.
    public func alerts(for accountID: UUID) -> NewMailAlerts? {
        _ = alertRevision
        let saved = environment.defaults.dictionary(forKey: "accountAlerts") as? [String: String] ?? [:]
        return saved[accountID.uuidString].flatMap(NewMailAlerts.init(rawValue:))
    }

    public func setAlerts(_ alerts: NewMailAlerts?, for accountID: UUID) {
        var saved = environment.defaults.dictionary(forKey: "accountAlerts") as? [String: String] ?? [:]
        saved[accountID.uuidString] = alerts?.rawValue
        environment.defaults.set(saved, forKey: "accountAlerts")
        alertRevision += 1
    }

    /// What one conversation's mailbox wants to hear about.
    func alertSetting(for thread: MailThread) -> NewMailAlerts {
        thread.accountID.flatMap(alerts(for:)) ?? newMailAlerts
    }

    func playAlertSound(_ sound: AlertSound? = nil) {
        #if os(macOS)
        let sound = sound ?? alertSound
        switch sound.name {
        case "none": return
        case "default": NSSound(named: "Glass")?.play()
        default: NSSound(named: sound.name)?.play()
        }
        #endif
    }

    /// Answers a conversation straight from an alert, from the address it came to.
    public func quickReply(to threadID: MailThread.ID, text: String) async -> Bool {
        guard let thread = inboxThreads(nil).first(where: { $0.id == threadID }), let account = account(thread.accountID),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var state = ComposeState(account: account, draft: Draft.reply(to: thread, from: account.replyAddress(for: thread)), isReply: true)
        state.draft.text = text + (state.signature.map { "\n\n" + $0 } ?? "")
        return await send(state)
    }
}

// MARK: Mailbox details

extension MailModel {
    /// Sets or clears a mailbox's picture, made small first.
    public func setPicture(_ data: Data?, for accountID: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].picture = data.flatMap { ImageResizer.resized($0, maxPixels: 256) }
        try? environment.accounts.save(accounts)
    }

    /// Changes a mailbox's servers or sign-in without removing it. The new settings are
    /// tried first; if they don't work, nothing changes.
    public func updateConnection(_ changed: MailAccount, secret: String?) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == changed.id }) else { return }
        let kind: String = switch changed.auth {
        case .password: "password"
        case .oauth: "oauth"
        case .token: "token"
        }
        let previous = environment.keychain.read(key: "\(changed.id.uuidString).\(kind)")
        if let secret, !secret.isEmpty {
            try environment.keychain.save(secret, account: changed.id, kind: kind)
            // A fresh sign-in: whatever made the last one pause no longer applies.
            await credentials.forgetPauses(for: changed.id)
        }
        do {
            let provider = try ProviderFactory.make(for: changed, credentials: credentials)
            _ = try await provider.mailboxes()
            if let old = providers.removeValue(forKey: changed.id) { Task { await old.disconnect() } }
            providers[changed.id] = provider
        } catch {
            if let previous { try? environment.keychain.save(previous, account: changed.id, kind: kind) }
            throw error
        }
        accounts[index] = changed
        try? environment.accounts.save(accounts)
        notice = Notice(text: String(localized: "\(changed.label) is connected"))
        await reload()
    }
}

// MARK: Signatures

extension MailModel {
    /// The signature this mailbox already ends sent mail with, read from its last sent messages.
    public func findSignatureInSentMail(_ accountID: UUID) async -> String? {
        guard let account = account(accountID), let sent = combinedMailbox(.sent, of: accountID),
              let provider = try? provider(for: account),
              let threads = try? await provider.threads(in: sent, limit: 40) else { return nil }
        var texts: [String] = []
        for thread in threads.prefix(30) {
            for message in thread.messages where message.from.address.caseInsensitiveCompare(account.address.address) == .orderedSame {
                if let body = message.body {
                    texts.append(body.text)
                } else if let body = try? await provider.body(of: message) {
                    texts.append(body.text)
                }
            }
        }
        return SignatureTools.find(in: texts)
    }

    /// Puts the formatted signature into an outgoing message, in place of the plain one.
    /// `after` is a last line that may follow the signature ("Sent from Margin"), kept after it.
    static func withFormattedSignature(_ draft: Draft, plain: String?, html signatureHTML: String?, after: String? = nil) -> Draft {
        guard let signatureHTML, !signatureHTML.isEmpty, let plain, !plain.isEmpty else { return draft }
        let tail = after.flatMap { draft.text.hasSuffix(plain + $0) ? $0 : nil } ?? ""
        guard draft.text.hasSuffix(plain + tail) else { return draft }
        var draft = draft
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        let block = "<div class=\"margin-signature\">\(signatureHTML)</div>"
        if var html = draft.html {
            let escaped = escape(plain.trimmingCharacters(in: .whitespacesAndNewlines))
            if let range = html.range(of: escaped, options: .backwards) {
                html.replaceSubrange(range, with: block)
            } else {
                html += block
            }
            draft.html = html
        } else {
            let body = String(draft.text.dropLast(plain.count + tail.count))
            let trailing = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.html = "<div>\(escape(body))</div>" + block + (trailing.isEmpty ? "" : "<div><br>\(escape(trailing))</div>")
        }
        return draft
    }
}
