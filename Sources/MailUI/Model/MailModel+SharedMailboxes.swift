import Foundation
import MailCore

/// Shared mailboxes on Microsoft 365: another mailbox the person may open (a team's sales@, a
/// colleague's who delegated it). Each is a mailbox of its own in Margin, opened through Graph's
/// `/users/{address}` with the person's own sign-in.
extension MailModel {
    /// Shared mailboxes can be added from a Microsoft mailbox of the person's own.
    public func canAddSharedMailbox(from account: MailAccount) -> Bool {
        guard case .graph(nil) = account.connection, case .oauth(.microsoft, _) = account.auth else { return false }
        return environment.oauth.client(for: .microsoft) != nil
    }

    /// The shared mailboxes opened with this mailbox's sign-in.
    public func sharedMailboxes(of account: MailAccount) -> [MailAccount] {
        guard case .oauth(.microsoft, let owner) = account.auth else { return [] }
        return accounts.filter { other in
            guard other.sharedMailbox != nil, case .oauth(.microsoft, let username) = other.auth else { return false }
            return username.lowercased() == owner.lowercased()
        }
    }

    /// Adds `address` as a mailbox of its own. The owner of `account` signs in once more on
    /// Microsoft's page (`authenticate`, the view's web sign-in), allowing shared mail, which
    /// work and school accounts can do and personal ones can't.
    public func addSharedMailbox(_ address: String, from account: MailAccount,
                                 authenticate: (URL, String) async throws -> URL) async throws {
        let address = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard EmailAddress.isValid(address) else { throw MailError.invalidAddress(address) }
        guard !accounts.contains(where: { $0.address.address.lowercased() == address }) else {
            throw MailError.notSupported(String(localized: "This mailbox is already in Margin."))
        }
        guard case .oauth(.microsoft, let username) = account.auth else { throw MailError.missingCredentials }
        let shared = MailAccount(label: address, address: EmailAddress(address: address),
                                 connection: .graph(sharedMailbox: address),
                                 auth: .oauth(provider: .microsoft, username: username), providerID: account.providerID)
        guard let client = environment.oauth.client(for: shared) else { throw MailError.missingCredentials }
        let request = client.authorizationRequest(loginHint: username)
        let callback = try await authenticate(request.url, client.callbackScheme)
        let tokens = try await client.exchange(callback: callback, verifier: request.verifier, state: request.state)
        try await add(shared, secret: String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self))
    }
}
