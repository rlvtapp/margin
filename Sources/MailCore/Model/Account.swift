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
    /// The default signature's pictures, which its HTML shows as `cid:` parts.
    public var signaturePictures: [OutgoingAttachment]?
    /// The default signature as the Mac's editor holds it (see `NamedSignature.rich`).
    public var signatureRich: Data?
    /// False keeps this mailbox out of All Inboxes; it still has its own inbox.
    public var inAllInboxes: Bool?
    /// The mailbox's picture (PNG, at most 256 pixels), shown instead of its letter.
    public var picture: Data?
    /// Signatures of send-as addresses that have their own, by lowercased address.
    public var aliasSignatures: [String: String]?
    /// Send-as addresses that use one of the mailbox's signatures, by lowercased address: the
    /// signature's name, or "" for none.
    public var aliasSignatureNames: [String: String]?
    /// False keeps this mailbox off the signatures shared by all mailboxes or its workspace;
    /// nil or true uses them when it has none of its own.
    public var usesSharedSignatures: Bool?
    /// The shared signatures this mailbox falls back on, filled in by the app (its workspace's,
    /// else all mailboxes'). Never saved.
    public var sharedSignatures = Unsaved<SharedSignatures>(nil)

    /// The main address first, then the aliases.
    public var sendAddresses: [EmailAddress] { [address] + (aliases ?? []) }

    /// The default signature with its formatting and pictures.
    public var defaultSignature: NamedSignature? {
        guard let signature else { return nil }
        return NamedSignature(name: NamedSignature.defaultName, text: signature, html: signatureHTML,
                              pictures: signaturePictures, rich: signatureRich)
    }

    /// Changes the default signature, or the one of `moreSignatures` with the same name.
    public mutating func setSignature(_ new: NamedSignature) {
        if new.name == NamedSignature.defaultName {
            let empty = new.isBlank
            signature = empty ? nil : new.text
            signatureHTML = empty ? nil : new.html
            signaturePictures = empty || new.pictures?.isEmpty != false ? nil : new.pictures
            signatureRich = empty ? nil : new.rich
        } else {
            setMoreSignature(new)
        }
    }

    public mutating func signatureRenamed(_ old: String, to new: String?) {
        if replySignature == old { replySignature = new }
        let names = aliasSignatureNames?.compactMapValues { $0 == old ? new : $0 }
        aliasSignatureNames = names?.isEmpty == true ? nil : names
    }

    /// The shared signatures in use: none when it has its own, or doesn't use them.
    public var inheritedSignatures: SharedSignatures? {
        guard allSignatures.isEmpty, usesSharedSignatures != false, let shared = sharedSignatures.value, !shared.allSignatures.isEmpty else { return nil }
        return shared
    }

    /// What can be picked while writing: its own signatures, then the shared ones (a shared
    /// default named after where it's from, when this mailbox has a default of its own).
    public var availableSignatures: [NamedSignature] {
        let own = allSignatures
        guard usesSharedSignatures != false, let shared = sharedSignatures.value else { return own }
        if own.isEmpty { return shared.allSignatures }
        var taken = Set(own.map(\.name))
        var more: [NamedSignature] = []
        for var picked in shared.allSignatures {
            if picked.name == NamedSignature.defaultName { picked.name = shared.title }
            guard !picked.name.isEmpty, taken.insert(picked.name).inserted else { continue }
            more.append(picked)
        }
        return own + more
    }

    /// The signature a new message (or a reply) starts with: its own, else the shared one.
    public func signatureChoice(forReply: Bool) -> NamedSignature? {
        if let inherited = inheritedSignatures { return inherited.ownChoice(forReply: forReply) }
        return ownChoice(forReply: forReply)
    }

    /// The signature text a new message (or a reply) starts with.
    public func signatureText(forReply: Bool) -> String? {
        signatureChoice(forReply: forReply)?.plainText
    }

    /// The signature for mail sent as `address`: the one picked for it, its own words, else the
    /// mailbox's.
    public func signatureChoice(sendingAs address: EmailAddress, forReply: Bool) -> NamedSignature? {
        let key = address.address.lowercased()
        if let name = aliasSignatureNames?[key] {
            return name.isEmpty ? nil : availableSignatures.first { $0.name == name } ?? signatureChoice(forReply: forReply)
        }
        if let own = aliasSignatures?[key], !own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NamedSignature(name: address.address, text: own)
        }
        return signatureChoice(forReply: forReply)
    }

    /// The signature for mail sent as `address`, as plain text.
    public func signature(sendingAs address: EmailAddress, forReply: Bool) -> String? {
        signatureChoice(sendingAs: address, forReply: forReply)?.plainText
    }

    /// True when mail sent as `address` gets a signature of its own rather than the mailbox's.
    public func hasOwnSignature(_ address: EmailAddress) -> Bool {
        let key = address.address.lowercased()
        return aliasSignatureNames?[key] != nil || aliasSignatures?[key] != nil
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

/// Somewhere signatures are kept: a mailbox, or signatures shared by several.
public protocol SignatureSet {
    /// The default signature, named "Default".
    var defaultSignature: NamedSignature? { get }
    /// More signatures to pick from while writing ("Casual", "Formal").
    var moreSignatures: [NamedSignature]? { get set }
    /// What replies and forwards use: nil for the default, "" for none, or one of
    /// `moreSignatures` by name.
    var replySignature: String? { get set }
    /// Changes the default signature, or the other one with the same name.
    mutating func setSignature(_ new: NamedSignature)
    /// A signature got another name, or was removed (nil): whatever used it follows.
    mutating func signatureRenamed(_ old: String, to new: String?)
}

extension SignatureSet {
    /// Every signature, the default first.
    public var allSignatures: [NamedSignature] {
        (defaultSignature.map { [$0] } ?? []) + (moreSignatures ?? [])
    }

    /// The one a new message (or a reply) starts with, of these.
    public func ownChoice(forReply: Bool) -> NamedSignature? {
        guard forReply, let choice = replySignature else { return defaultSignature }
        if choice.isEmpty { return nil }
        return moreSignatures?.first { $0.name == choice } ?? defaultSignature
    }

    mutating func setMoreSignature(_ new: NamedSignature) {
        if let index = moreSignatures?.firstIndex(where: { $0.name == new.name }) {
            moreSignatures?[index] = new
        } else {
            moreSignatures = (moreSignatures ?? []) + [new]
        }
    }

    /// Puts back a signature from its editor: the default, a renamed one (whatever pointed at
    /// its old name follows it), or a new one. `original` is the name it had, nil for a new one.
    public mutating func saveSignature(_ saved: NamedSignature, replacing original: String?) {
        if original == NamedSignature.defaultName {
            var main = saved
            main.name = NamedSignature.defaultName
            setSignature(main)
        } else if let original, let index = moreSignatures?.firstIndex(where: { $0.name == original }) {
            moreSignatures?[index] = saved
            if original != saved.name { signatureRenamed(original, to: saved.name) }
        } else {
            moreSignatures = (moreSignatures ?? []) + [saved]
        }
    }

    /// Removes a signature; the default one is emptied. Whatever used it goes back to the default.
    public mutating func removeSignature(named name: String) {
        if name == NamedSignature.defaultName {
            setSignature(NamedSignature(name: NamedSignature.defaultName, text: ""))
            return
        }
        moreSignatures?.removeAll { $0.name == name }
        if moreSignatures?.isEmpty == true { moreSignatures = nil }
        signatureRenamed(name, to: nil)
    }

    /// `name`, or "name 2", "name 3"… when another signature already has it.
    public func freeSignatureName(_ name: String) -> String {
        let taken = Set(allSignatures.map(\.name) + [NamedSignature.defaultName])
        guard taken.contains(name) else { return name }
        return (2...).lazy.map { "\(name) \($0)" }.first { !taken.contains($0) } ?? name
    }

    /// Takes in a signature from somewhere else: as the default, or next to the others (a
    /// default from elsewhere is named after where it came from, `sourceName`).
    public mutating func copySignature(_ signature: NamedSignature, from sourceName: String, asDefault: Bool) {
        var copy = signature
        if asDefault {
            copy.name = NamedSignature.defaultName
            setSignature(copy)
        } else {
            copy.name = freeSignatureName(signature.name == NamedSignature.defaultName ? sourceName : signature.name)
            moreSignatures = (moreSignatures ?? []) + [copy]
        }
    }
}

extension MailAccount: SignatureSet {}

/// Signatures several mailboxes share: all of them, or one workspace's. A mailbox without
/// signatures of its own starts mail with these.
public struct SharedSignatures: Codable, Hashable, Sendable, SignatureSet {
    public var defaultSignature: NamedSignature?
    public var moreSignatures: [NamedSignature]?
    public var replySignature: String?
    /// Where they're from ("All Inboxes", a workspace's name), set when they're handed to a
    /// mailbox; it names the shared default next to a mailbox's own.
    public var title = ""

    public init(defaultSignature: NamedSignature? = nil, moreSignatures: [NamedSignature]? = nil, replySignature: String? = nil) {
        self.defaultSignature = defaultSignature
        self.moreSignatures = moreSignatures
        self.replySignature = replySignature
    }

    public mutating func setSignature(_ new: NamedSignature) {
        if new.name == NamedSignature.defaultName {
            defaultSignature = new.isBlank ? nil : new
        } else {
            setMoreSignature(new)
        }
    }

    public mutating func signatureRenamed(_ old: String, to new: String?) {
        if replySignature == old { replySignature = new }
    }

    public var isEmpty: Bool { allSignatures.isEmpty }
}

/// Kept in memory only: never saved (its key is left out), read back empty, and never makes
/// two values different, so a mailbox read from disk equals the same one in memory.
public struct Unsaved<Value: Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value?

    public init(_ value: Value?) { self.value = value }
    public init(from decoder: Decoder) throws { value = nil }
    public func encode(to encoder: Encoder) throws {}
    public static func == (lhs: Self, rhs: Self) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
}

extension KeyedDecodingContainer {
    /// An `Unsaved` property reads back empty whether or not its key is there.
    public func decode<T>(_ type: Unsaved<T>.Type, forKey key: Key) throws -> Unsaved<T> { Unsaved(nil) }
}

extension KeyedEncodingContainer {
    /// An `Unsaved` property writes nothing, not even its key.
    public mutating func encode<T>(_ value: Unsaved<T>, forKey key: Key) throws {}
}

/// A signature with a name to pick it by. It can be formatted, with pictures: `text` is then
/// what the Mac's editor holds (a picture is one U+FFFC character), `html` what's sent, and
/// `pictures` the parts its HTML shows.
public struct NamedSignature: Hashable, Codable, Sendable, Identifiable {
    public static let defaultName = "Default"
    /// Stands in for a picture in `text`, as in the editor.
    public static let pictureCharacter: Character = "\u{FFFC}"
    public var id: String { name }
    public var name: String
    public var text: String
    /// The formatted version that's sent; nil for a plain signature.
    public var html: String?
    /// Pictures the HTML shows (`cid:`), sent as inline parts.
    public var pictures: [OutgoingAttachment]?
    /// The formatting for the Mac's editor (an archived attributed string whose pictures are
    /// kept in `pictures`). Nil for a plain signature, or one written as HTML.
    public var rich: Data?

    public init(name: String, text: String, html: String? = nil, pictures: [OutgoingAttachment]? = nil, rich: Data? = nil) {
        self.name = name
        self.text = text
        self.html = html
        self.pictures = pictures
        self.rich = rich
    }

    /// True when it has formatting or pictures to send.
    public var isFormatted: Bool { !(html ?? "").isEmpty }

    /// No words and no pictures.
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pictures?.isEmpty != false }

    /// The words alone: pictures left out, and the lines that only held one.
    public var plainText: String {
        guard text.contains(Self.pictureCharacter) else { return text }
        return text.components(separatedBy: "\n")
            .compactMap { line -> String? in
                let words = line.filter { $0 != Self.pictureCharacter }
                return words.trimmingCharacters(in: .whitespaces).isEmpty && line.contains(Self.pictureCharacter) ? nil : words
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same words without formatting or pictures.
    public var plain: NamedSignature { NamedSignature(name: name, text: plainText) }

    /// The HTML with its pictures in it, to show it before it's sent.
    public var previewHTML: String? {
        guard var html, !html.isEmpty else { return nil }
        for picture in pictures ?? [] {
            guard let id = picture.contentID else { continue }
            html = html.replacingOccurrences(of: "cid:\(id)", with: "data:\(picture.mimeType);base64,\(picture.data.base64EncodedString())")
        }
        return html
    }
}
