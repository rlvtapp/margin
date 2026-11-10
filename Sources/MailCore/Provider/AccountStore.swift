import Foundation

/// The list of accounts, saved as JSON in Application Support. Secrets are not in it;
/// they live in the Keychain under each account's id.
public struct AccountStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func standard(appName: String) -> AccountStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AccountStore(fileURL: base.appending(path: appName, directoryHint: .isDirectory).appending(path: "accounts.json"))
    }

    /// Saved accounts, or the two sample accounts on first launch.
    public func load() -> [MailAccount] {
        guard let data = try? Data(contentsOf: fileURL),
              let accounts = try? JSONDecoder().decode([MailAccount].self, from: data), !accounts.isEmpty else {
            return [.sample, .samplePersonal]
        }
        return accounts
    }

    public func save(_ accounts: [MailAccount]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: fileURL, options: .atomic)
    }
}

/// Makes the right provider for an account.
public enum ProviderFactory {
    public static func make(for account: MailAccount, credentials: any CredentialSource) throws -> any MailProvider {
        switch account.connection {
        case .sample: SampleProvider(me: account.address, variant: account.id == MailAccount.samplePersonal.id ? .personal : .work)
        case .imap: try IMAPProvider(account: account, credentials: credentials)
        case .jmap: try JMAPProvider(account: account, credentials: credentials)
        }
    }
}
