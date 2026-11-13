import Foundation
import MailCore

/// Signing in to a mailbox that's already set up, without removing it: only the sign-in kept in
/// the Keychain is replaced. Saved mail, labels, rules, settings and the mailbox's place in the
/// list all stay as they are.
extension MailModel {
    /// The mailbox signs in on the provider's own page (Google, Microsoft) instead of with a password.
    public func signsInOnTheWeb(_ account: MailAccount) -> Bool {
        if case .oauth = account.auth { true } else { false }
    }

    /// Sample mailboxes have nothing to sign in to.
    public func canSignInAgain(_ account: MailAccount) -> Bool {
        account.connection != .sample
    }

    /// The provider refused this mailbox's sign-in, so signing in again is what helps.
    public func needsSignIn(_ id: UUID) -> Bool {
        loadErrors[id] != nil && signInRefused.contains(id)
    }

    /// The first mailbox in view whose sign-in was refused, for the "Sign in again" next to the
    /// status line. Mailboxes of a workspace that isn't showing stay quiet until it is.
    public var accountNeedingSignIn: MailAccount? {
        workspaceAccounts.first { needsSignIn($0.id) && canSignInAgain($0) }
    }

    /// Google and Microsoft: opens the provider's sign-in (`authenticate` is the view's web
    /// authentication session and returns the callback URL) and keeps the new sign-in.
    public func signInAgain(_ account: MailAccount, authenticate: (URL, String) async throws -> URL) async throws {
        guard case .oauth(let provider, _) = account.auth,
              let client = environment.oauth.client(for: provider) else { throw MailError.missingCredentials }
        let request = client.authorizationRequest(loginHint: account.address.address)
        let callback = try await authenticate(request.url, client.callbackScheme)
        let tokens = try await client.exchange(callback: callback, verifier: request.verifier, state: request.state)
        // Whether it's the right account is proved by the mail server taking the new sign-in for
        // this mailbox (`useSignIn`), not by comparing names: the name a provider signs people in
        // under is often not the mailbox's address (an alias, a work sign-in name on another
        // domain), and turning those away made signing in again fail for good mailboxes.
        try await useSignIn(String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self), for: account, signedInAs: tokens.signedInAs)
        // Microsoft: one sign-in covers contacts, the calendar and the rest that was turned on.
        if provider == .microsoft, !(apiAccess[account.id] ?? []).isEmpty, (try? await credentials.apiToken(for: account)) == nil {
            try? await credentials.renewAPITokens(from: tokens, for: account)
            await refreshContacts()
        }
    }

    /// Password and token mailboxes: tries the new password, and keeps it only if it works.
    public func signInAgain(_ account: MailAccount, secret: String) async throws {
        try await useSignIn(secret, for: account)
    }

    /// Swaps the saved sign-in and proves it against the server. `prove` is the check (tests
    /// stand in for the server). When the server refuses the new sign-in (a wrong password,
    /// another account chosen on the provider's page), it's thrown away and the old one put
    /// back. When the server just couldn't be reached, a new password is put back too, but a new
    /// provider sign-in is kept: it's good, and the old one is spent.
    func useSignIn(_ secret: String, for account: MailAccount, signedInAs: String? = nil,
                   prove: ((any MailProvider) async throws -> Void)? = nil) async throws {
        let kind: String = switch account.auth {
        case .password: "password"
        case .oauth: "oauth"
        case .token: "token"
        }
        let previous = environment.keychain.read(account: account.id, kind: kind)
        try environment.keychain.save(secret, account: account.id, kind: kind)
        await credentials.forgetPauses(for: account.id)
        // The open connection was made with the old sign-in.
        if let old = providers.removeValue(forKey: account.id) { await old.disconnect() }
        do {
            let provider = try ProviderFactory.make(for: account, credentials: credentials)
            if let prove { try await prove(provider) } else { _ = try await provider.mailboxes() }
            providers[account.id] = provider
        } catch {
            let refused = Self.isSignInRefusal(error)
            if refused || !signsInOnTheWeb(account), let previous {
                try? environment.keychain.save(previous, account: account.id, kind: kind)
                await credentials.forgetPauses(for: account.id)
            }
            // Refused, and the provider says someone else signed in: say that, it's the likely cause.
            let mine = Set(([account.address] + (account.aliases ?? [])).map { $0.address.lowercased() })
            if refused, let who = signedInAs, !mine.contains(who.lowercased()) {
                throw MailError.authenticationFailed(String(localized: "You signed in as \(who). Sign in again and choose \(account.address.address)."))
            }
            throw error
        }
        loadErrors[account.id] = nil
        unreachable.remove(account.id)
        signInRefused.remove(account.id)
        notice = Notice(text: String(localized: "Signed in to \(account.label) again."), isError: false)
        // Whatever was waiting for new mail did so with the old sign-in: it starts over.
        watchers.removeValue(forKey: account.id)?.cancel()
        Task {
            await reload()
            if clock != nil { startWatching() }
        }
    }
}
