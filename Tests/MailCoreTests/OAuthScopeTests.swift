import Foundation
import Testing
@testable import MailCore

@Suite struct OAuthScopeTests {
    private let registry = OAuthClientRegistry(googleClientID: "123-abc.apps.googleusercontent.com", microsoftClientID: "client")

    @Test func microsoftSignInAsksForOpenIDWithEmail() throws {
        let client = try #require(registry.client(for: .microsoft))
        let url = client.authorizationRequest(loginHint: nil).url
        let scope = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value)
        let scopes = scope.split(separator: " ").map(String.init)
        #expect(scopes.contains("openid"))
        #expect(scopes.contains("email"))
        // Consent for push is asked up front, alongside mail.
        #expect(scopes.contains("https://graph.microsoft.com/Mail.ReadBasic"))
    }

    @Test func microsoftTokensAreForOneServiceOnly() throws {
        let client = try #require(registry.client(for: .microsoft))
        #expect(client.tokenScopes == [
            "https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send",
            "offline_access", "openid", "email", "profile",
        ])
    }

    @Test func aGraphOnlyClientKeepsItsScopes() throws {
        var client = try #require(registry.client(for: .microsoft))
        client.scopes = ["https://graph.microsoft.com/Mail.ReadBasic", "offline_access"]
        #expect(client.tokenScopes == client.scopes)
    }
}
