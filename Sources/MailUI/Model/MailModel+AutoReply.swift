import Foundation
import MailCore

/// Out-of-office replies, kept by each provider: Microsoft and Google through their APIs (asked for
/// the first time it's opened), JMAP servers through VacationResponse.
extension MailModel {
    public enum AutoReplySupport: Equatable {
        /// Ready to read and change.
        case ready
        /// Microsoft or Google: needs the account to allow it first.
        case needsAccess
        /// Plain IMAP: the provider's website is the place.
        case unavailable
    }

    public func autoReplySupport(_ account: MailAccount) -> AutoReplySupport {
        if case .jmap = account.connection { return .ready }
        guard oauthProvider(of: account) != nil else { return .unavailable }
        return apiAccess[account.id]?.contains(.autoReply) == true ? .ready : .needsAccess
    }

    func autoReplyAdapter(for account: MailAccount) async throws -> any AutoReplyAdapter {
        if case .jmap = account.connection, let jmap = try provider(for: account) as? JMAPProvider { return jmap }
        let token = try await credentials.apiToken(for: account)
        switch oauthProvider(of: account) {
        case .microsoft: return MicrosoftAutoReply(accessToken: token)
        case .google: return GmailAutoReply(accessToken: token)
        case nil: throw MailError.notSupported(String(localized: "Set automatic replies on your provider's website."))
        }
    }

    public func autoReply(for account: MailAccount) async throws -> AutoReply {
        try await autoReplyAdapter(for: account).autoReply()
    }

    public func setAutoReply(_ reply: AutoReply, for account: MailAccount) async throws {
        try await autoReplyAdapter(for: account).setAutoReply(reply)
        notice = Notice(text: reply.isOn ? String(localized: "Automatic reply is on") : String(localized: "Automatic reply is off"))
    }
}
