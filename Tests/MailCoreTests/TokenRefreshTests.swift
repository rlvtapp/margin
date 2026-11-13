import Foundation
import Testing
@testable import MailCore

/// Counts refresh requests, and can be told to fail.
private actor TokenEndpoint {
    var calls = 0
    var failure: Error?

    func fail(with error: Error?) { failure = error }

    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        calls += 1
        // Long enough for everyone else to arrive while this one is still out.
        try await Task.sleep(for: .milliseconds(120))
        if let failure { throw failure }
        return OAuthTokens(accessToken: "fresh-\(calls)", refreshToken: tokens.refreshToken, expiresAt: Date().addingTimeInterval(3600))
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

/// Microsoft's refresh tokens are replaced with every token it hands out.
private actor RotatingEndpoint {
    var calls = 0
    var used: [String] = []
    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        calls += 1
        used.append(tokens.refreshToken ?? "")
        return OAuthTokens(accessToken: "access-\(calls)", refreshToken: "refresh-\(calls)", expiresAt: Date().addingTimeInterval(3600))
    }
}

@Suite struct RefreshTokenRotationTests {
    /// A token fetched for notifications comes with a new refresh token: the mail sign-in keeps
    /// it, so its own next refresh doesn't use one the provider has retired.
    @Test func theMailSignInKeepsTheNewestRefreshToken() async throws {
        let keychain = Keychain(service: "margin.token-rotation-test.\(UUID().uuidString)")
        let account = MailAccount(label: "Work", address: EmailAddress(address: "alex@example.com"),
                                  connection: .jmap(sessionURL: URL(string: "https://example.invalid")!),
                                  auth: .oauth(provider: .microsoft, username: "alex@example.com"))
        defer { keychain.delete(key: "\(account.id.uuidString).oauth") }
        // The mail token is still good for a while.
        let current = OAuthTokens(accessToken: "mail", refreshToken: "first", expiresAt: Date().addingTimeInterval(1800))
        try keychain.save(String(decoding: try JSONEncoder().encode(current), as: UTF8.self), account: account.id, kind: "oauth")
        let endpoint = RotatingEndpoint()
        let clock = Clock()
        let credentials = KeychainCredentials(keychain: keychain, oauth: OAuthClientRegistry(googleClientID: nil, microsoftClientID: "client"),
                                              now: { clock.now }, refresh: { _, tokens in try await endpoint.refresh(tokens) })

        #expect(try await credentials.pushToken(for: account) == "access-1")
        let stored = try JSONDecoder().decode(OAuthTokens.self, from: Data((keychain.read(account: account.id, kind: "oauth") ?? "").utf8))
        // The newest refresh token is kept; the mail token itself is untouched.
        #expect(stored.refreshToken == "refresh-1")
        #expect(stored.accessToken == "mail")
        #expect(try await credentials.secret(for: account) == "mail")
        #expect(await endpoint.used == ["first"])
    }
}

@Suite struct TokenRefreshTests {
    private func setUp() throws -> (credentials: KeychainCredentials, endpoint: TokenEndpoint, clock: Clock, account: MailAccount, keychain: Keychain) {
        let keychain = Keychain(service: "margin.token-refresh-test.\(UUID().uuidString)")
        let account = MailAccount(label: "Work", address: EmailAddress(address: "alex@example.com"),
                                  connection: .jmap(sessionURL: URL(string: "https://example.invalid")!),
                                  auth: .oauth(provider: .microsoft, username: "alex@example.com"))
        // A sign-in whose access token has run out.
        let expired = OAuthTokens(accessToken: "old", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(-60))
        try keychain.save(String(decoding: try JSONEncoder().encode(expired), as: UTF8.self), account: account.id, kind: "oauth")
        let endpoint = TokenEndpoint()
        let clock = Clock()
        let credentials = KeychainCredentials(keychain: keychain, oauth: OAuthClientRegistry(googleClientID: nil, microsoftClientID: "client"),
                                              now: { clock.now }, refresh: { _, tokens in try await endpoint.refresh(tokens) })
        return (credentials, endpoint, clock, account, keychain)
    }

    @Test func aBurstOfCallersMakesOneRequest() async throws {
        let (credentials, endpoint, _, account, keychain) = try setUp()
        defer { keychain.delete(key: "\(account.id.uuidString).oauth") }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<40 { group.addTask { try await credentials.secret(for: account) } }
            var all: [String] = []
            for try await token in group { all.append(token) }
            return all
        }
        #expect(tokens.count == 40)
        #expect(Set(tokens) == ["fresh-1"])
        #expect(await endpoint.calls == 1)
        // And the new token is kept: the next caller asks nobody.
        #expect(try await credentials.secret(for: account) == "fresh-1")
        #expect(await endpoint.calls == 1)
    }

    @Test func aRefusalIsNotAskedAgainStraightAway() async throws {
        let (credentials, endpoint, clock, account, keychain) = try setUp()
        defer { keychain.delete(key: "\(account.id.uuidString).oauth") }
        await endpoint.fail(with: MailError.authenticationFailed("AADSTS50196: The server terminated an operation because it encountered a client request loop."))
        for _ in 0..<25 {
            await #expect(throws: (any Error).self) { try await credentials.secret(for: account) }
        }
        // Twenty-five tries, one request: the rest were told to wait.
        #expect(await endpoint.calls == 1)

        // Still quiet a few minutes on; then it tries once more, and works.
        clock.advance(4 * 60)
        await #expect(throws: (any Error).self) { try await credentials.secret(for: account) }
        #expect(await endpoint.calls == 1)
        await endpoint.fail(with: nil)
        clock.advance(3 * 60)
        #expect(try await credentials.secret(for: account) == "fresh-2")
        #expect(await endpoint.calls == 2)
    }

    @Test func signingInAgainLiftsThePause() async throws {
        let (credentials, endpoint, _, account, keychain) = try setUp()
        defer { keychain.delete(key: "\(account.id.uuidString).oauth") }
        await endpoint.fail(with: MailError.authenticationFailed("invalid_grant"))
        await #expect(throws: (any Error).self) { try await credentials.secret(for: account) }
        await endpoint.fail(with: nil)
        await #expect(throws: (any Error).self) { try await credentials.secret(for: account) }
        #expect(await endpoint.calls == 1)
        await credentials.forgetPauses(for: account.id)
        #expect(try await credentials.secret(for: account) == "fresh-2")
    }

    @Test func howLongToWaitDependsOnWhatWentWrong() {
        #expect(KeychainCredentials.pause(after: URLError(.notConnectedToInternet)).seconds == 15)
        #expect(KeychainCredentials.pause(after: MailError.authenticationFailed("AADSTS50196: client request loop")).seconds == 360)
        #expect(KeychainCredentials.pause(after: MailError.authenticationFailed("invalid_grant: expired")).seconds == 900)
        // Throttling is retried as a connection problem, without asking for a new sign-in.
        #expect(MailError.isConnectionProblem(KeychainCredentials.pause(after: MailError.authenticationFailed("AADSTS50196: loop")).error))
        // The loop message is replaced with one that says what's happening.
        #expect(!KeychainCredentials.pause(after: MailError.authenticationFailed("AADSTS50196: loop")).error.localizedDescription.contains("AADSTS"))
    }
}
