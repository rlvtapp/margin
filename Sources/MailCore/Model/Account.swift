import Foundation

/// How a connection is secured. STARTTLS upgrades a plain connection before
/// anything private is sent; `plain` exists only for local servers (tests, bridges).
public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    case tls, startTLS, plain
}

public struct ServerEndpoint: Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity

    public init(host: String, port: Int, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    /// Plain connections are only allowed to this machine.
    public var isAllowed: Bool {
        security != .plain || ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }
}

/// How the app proves who you are. Secrets never live here: they are in the Keychain,
/// stored under the account id.
public enum AuthMethod: Hashable, Codable, Sendable {
    /// A password or an app password.
    case password(username: String)
    /// OAuth 2.0 (Google, Microsoft). The token is sent with SASL XOAUTH2.
    case oauth(provider: OAuthProviderID, username: String)
    /// A bearer token (JMAP API tokens).
    case token
}

/// Which protocol family the account speaks.
public enum AccountConnection: Hashable, Codable, Sendable {
    /// Built-in sample mail, so the app can be tried without an account.
    case sample
    /// IMAP for reading, SMTP for sending (RFC 9051 / RFC 3501, RFC 5321).
    case imap(incoming: ServerEndpoint, outgoing: ServerEndpoint)
    /// JMAP for both (RFC 8620, RFC 8621).
    case jmap(sessionURL: URL)
}

public struct MailAccount: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// What the sidebar calls it ("Work", "Personal").
    public var label: String
    public var address: EmailAddress
    public var connection: AccountConnection
    public var auth: AuthMethod
    /// The catalog entry it was set up from, for the icon and help links.
    public var providerID: String?
    /// Which colour marks this account in combined views (an index into the app's palette).
    public var colorIndex: Int
    /// Added under new messages and replies from this mailbox: the default signature.
    public var signature: String?
    /// Other addresses this mailbox can send as (send-as aliases such as sales@), each with
    /// its own name if it has one.
    public var aliases: [EmailAddress]?
    /// More signatures to pick from while writing ("Casual", "Formal").
    public var moreSignatures: [NamedSignature]?
    /// What replies and forwards use: nil for the default signature, "" for none, or the name
    /// of one of `moreSignatures`.
    public var replySignature: String?
    /// A formatted version of the default signature (HTML), used when sending. The plain
    /// `signature` stays for plain-text mail and as the fallback.
    public var signatureHTML: String?
    /// False keeps this mailbox out of All Inboxes; it still has its own inbox.
    public var inAllInboxes: Bool?
    /// The mailbox's picture (PNG, at most 256 pixels), shown instead of its letter.
    public var picture: Data?

    /// The main address first, then the aliases.
    public var sendAddresses: [EmailAddress] { [address] + (aliases ?? []) }

    /// Every signature by name, the default first (named "Default").
    public var allSignatures: [NamedSignature] {
        let main = signature.map { [NamedSignature(name: NamedSignature.defaultName, text: $0)] } ?? []
        return main + (moreSignatures ?? [])
    }

    /// The signature text a new message (or a reply) starts with.
    public func signatureText(forReply: Bool) -> String? {
        guard forReply, let choice = replySignature else { return signature }
        if choice.isEmpty { return nil }
        return moreSignatures?.first { $0.name == choice }?.text ?? signature
    }

    /// The address to answer from: the alias the mail was sent to, or the main address.
    public func replyAddress(for thread: MailThread) -> EmailAddress {
        let received = thread.messages.flatMap { $0.to + $0.cc }.map { $0.address.lowercased() }
        return (aliases ?? []).first { received.contains($0.address.lowercased()) } ?? address
    }

    public init(
        id: UUID = UUID(), label: String, address: EmailAddress, connection: AccountConnection,
        auth: AuthMethod, providerID: String? = nil, colorIndex: Int = 0
    ) {
        self.id = id
        self.label = label
        self.address = address
        self.connection = connection
        self.auth = auth
        self.providerID = providerID
        self.colorIndex = colorIndex
    }

    /// Two sample accounts, so the combined inbox can be tried without signing in.
    public static let sample = MailAccount(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000A11C")!,
        label: "Work",
        address: EmailAddress(name: "Alex Rivera", address: "alex@northwind.example"),
        connection: .sample,
        auth: .token,
        colorIndex: 0
    )

    public static let samplePersonal = MailAccount(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000A11D")!,
        label: "Personal",
        address: EmailAddress(name: "Alex Rivera", address: "alex.rivera@homemail.example"),
        connection: .sample,
        auth: .token,
        colorIndex: 1
    )

    /// The host the app talks to, shown so it's always clear where mail goes.
    public var serverDescription: String {
        switch connection {
        case .sample: String(localized: "On this device")
        case .imap(let incoming, _): incoming.host
        case .jmap(let url): url.host() ?? url.absoluteString
        }
    }
}

/// A signature with a name to pick it by.
public struct NamedSignature: Hashable, Codable, Sendable, Identifiable {
    public static let defaultName = "Default"
    public var id: String { name }
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}
