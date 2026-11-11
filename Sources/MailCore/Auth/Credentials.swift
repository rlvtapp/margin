import Foundation
import Security

/// Where providers get the secret for an account: a password, an app password, or a
/// fresh OAuth access token.
public protocol CredentialSource: Sendable {
    func secret(for account: MailAccount) async throws -> String
}

/// Secrets in the system Keychain, one item per account and kind. With Sync with iCloud on,
/// they're iCloud Keychain items, end-to-end encrypted by Apple and on every device signed in to
/// the same Apple Account; otherwise they never leave this device.
public struct Keychain: Sendable {
    public let service: String

    /// Set when Sync with iCloud is on (standard defaults, so every part of the app agrees).
    public static let syncKey = "syncsSecretsWithICloud"

    public init(service: String) { self.service = service }

    var synchronizes: Bool { UserDefaults.standard.bool(forKey: Self.syncKey) }

    public func save(_ value: String, account: UUID, kind: String) throws {
        try save(value, key: "\(account.uuidString).\(kind)")
    }

    public func read(account: UUID, kind: String) -> String? {
        read(key: "\(account.uuidString).\(kind)")
    }

    /// Secrets that belong to the app rather than an account (assistant API keys, the MCP token).
    /// Secrets already read this launch. Each Keychain read of an item can ask for the Mac's
    /// password (when the item was made by another build), so each is read once, then kept.
    private static let memory = Memory()

    final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func get(_ key: String) -> String? { lock.withLock { values[key] } }
        func set(_ key: String, _ value: String?) { lock.withLock { values[key] = value } }
    }

    private func memoryKey(_ key: String) -> String { service + "|" + key }

    public func save(_ value: String, key: String) throws {
        delete(key: key)
        defer { Self.memory.set(memoryKey(key), value) }
        if synchronizes {
            // iCloud Keychain lives in the data protection keychain. A build that isn't signed
            // for it can't write there; the secret then stays on this device.
            var item = base(key)
            item[kSecUseDataProtectionKeychain as String] = true
            item[kSecAttrSynchronizable as String] = true
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return }
        }
        var item = base(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func read(key: String) -> String? {
        if let known = Self.memory.get(memoryKey(key)) { return known }
        let value = readFromKeychain(key: key)
        if let value { Self.memory.set(memoryKey(key), value) }
        return value
    }

    private func readFromKeychain(key: String) -> String? {
        // Synced items first, then ones kept on this device.
        for dataProtection in [true, false] {
            var query = base(key)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    public func delete(key: String) {
        Self.memory.set(memoryKey(key), nil)
        for dataProtection in [true, false] {
            var query = base(key)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
            SecItemDelete(query as CFDictionary)
        }
    }

    public func deleteAll(account: UUID) {
        for kind in ["password", "oauth", "token", "api"] {
            delete(key: "\(account.uuidString).\(kind)")
        }
    }

    /// Saves each secret again, so it moves into or out of iCloud Keychain after the switch changed.
    public func resave(keys: [String]) {
        for key in keys {
            if let value = read(key: key) { try? save(value, key: key) }
        }
    }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? String(localized: "Keychain error \(status).")
    }
}

/// The app's credential source: passwords and tokens from the Keychain, OAuth tokens
/// refreshed against the provider when they're about to expire.
public actor KeychainCredentials: CredentialSource {
    private let keychain: Keychain
    private let oauth: OAuthClientRegistry

    public init(keychain: Keychain, oauth: OAuthClientRegistry) {
        self.keychain = keychain
        self.oauth = oauth
    }

    private var pushTokens: [UUID: OAuthTokens] = [:]

    /// A token for asking the provider to report new mail: the mail sign-in itself for Google,
    /// and for Microsoft, a Graph token redeemed from the same sign-in.
    public func pushToken(for account: MailAccount) async throws -> String {
        guard case .oauth(let provider, _) = account.auth else { return try await secret(for: account) }
        if provider == .google { return try await secret(for: account) }
        if let cached = pushTokens[account.id], !cached.isExpiring { return cached.accessToken }
        guard let stored = keychain.read(account: account.id, kind: "oauth"),
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(stored.utf8)),
              var client = oauth.client(for: .microsoft) else { throw MailError.missingCredentials }
        client.scopes = ["https://graph.microsoft.com/Mail.ReadBasic", "offline_access"]
        let fresh = try await client.refresh(tokens)
        pushTokens[account.id] = fresh
        return fresh.accessToken
    }

    /// The addresses a Microsoft 365 mailbox also receives at (its aliases), from the account's
    /// own profile; empty when Microsoft won't say (personal accounts, or no consent to read it).
    public func microsoftAliases(for account: MailAccount) async -> [String] {
        guard case .oauth(.microsoft, _) = account.auth,
              let stored = keychain.read(account: account.id, kind: "oauth"),
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(stored.utf8)),
              var client = oauth.client(for: .microsoft) else { return [] }
        client.scopes = ["https://graph.microsoft.com/User.Read", "offline_access"]
        guard let fresh = try? await client.refresh(tokens),
              var request = Optional(URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=proxyAddresses")!)) else { return [] }
        request.setValue("Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addresses = object["proxyAddresses"] as? [String] else { return [] }
        // "SMTP:" is the primary address, "smtp:" the others.
        return addresses.filter { $0.hasPrefix("smtp:") }.map { String($0.dropFirst(5)) }
    }

    /// What the account's API tokens were granted for, if any.
    public func apiAccess(for account: MailAccount) -> Set<APIAccess> {
        storedAPITokens(account)?.access ?? []
    }

    public func saveAPITokens(_ tokens: APITokens, for account: MailAccount) throws {
        try keychain.save(String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self), account: account.id, kind: "api")
    }

    /// Narrows what the account's API tokens are used for (the next refresh asks only for that).
    /// Nothing left: the tokens are forgotten.
    public func setAPIAccess(_ access: Set<APIAccess>, for account: MailAccount) throws {
        guard let stored = storedAPITokens(account) else { return }
        if access.isEmpty { removeAPITokens(for: account); return }
        try saveAPITokens(APITokens(tokens: stored.tokens, access: access), for: account)
    }

    public func removeAPITokens(for account: MailAccount) {
        keychain.delete(key: "\(account.id.uuidString).api")
    }

    /// A fresh access token for the account's contacts, calendar and rooms APIs.
    public func apiToken(for account: MailAccount) async throws -> String {
        guard case .oauth(let provider, _) = account.auth, let stored = storedAPITokens(account) else {
            throw MailError.missingCredentials
        }
        if !stored.tokens.isExpiring { return stored.tokens.accessToken }
        guard let client = oauth.client(for: provider, access: stored.access) else { throw MailError.missingCredentials }
        let fresh = APITokens(tokens: try await client.refresh(stored.tokens), access: stored.access)
        try saveAPITokens(fresh, for: account)
        return fresh.tokens.accessToken
    }

    private func storedAPITokens(_ account: MailAccount) -> APITokens? {
        keychain.read(account: account.id, kind: "api").flatMap { try? JSONDecoder().decode(APITokens.self, from: Data($0.utf8)) }
    }

    public func secret(for account: MailAccount) async throws -> String {
        switch account.auth {
        case .password:
            guard let password = keychain.read(account: account.id, kind: "password") else { throw MailError.missingCredentials }
            return password
        case .token:
            guard let token = keychain.read(account: account.id, kind: "token") else { throw MailError.missingCredentials }
            return token
        case .oauth(let provider, _):
            guard let stored = keychain.read(account: account.id, kind: "oauth"),
                  let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(stored.utf8)) else {
                throw MailError.missingCredentials
            }
            if !tokens.isExpiring { return tokens.accessToken }
            guard let client = oauth.client(for: provider) else { throw MailError.missingCredentials }
            let fresh = try await client.refresh(tokens)
            let encoded = String(decoding: try JSONEncoder().encode(fresh), as: UTF8.self)
            try keychain.save(encoded, account: account.id, kind: "oauth")
            return fresh.accessToken
        }
    }
}
