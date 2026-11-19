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
        // Mail is read and sent through Graph, so the whole sign-in is one Graph token.
        #expect(client.tokenScopes == [
            "https://graph.microsoft.com/Mail.ReadWrite", "https://graph.microsoft.com/Mail.Send",
            "https://graph.microsoft.com/Mail.ReadBasic", "offline_access", "openid", "email", "profile",
        ])
    }

    @Test func aGraphOnlyClientKeepsItsScopes() throws {
        var client = try #require(registry.client(for: .microsoft))
        client.scopes = ["https://graph.microsoft.com/Mail.ReadBasic", "offline_access"]
        #expect(client.tokenScopes == client.scopes)
    }

    /// The calendar asks for shared calendars too (suggested meeting times). Connections made
    /// before don't have that: a refresh that's turned down tries again without it.
    @Test func calendarAccessAsksForSharedCalendarsAndOlderConnectionsStillRefresh() async throws {
        var client = try #require(registry.client(for: .microsoft, access: [.calendar]))
        #expect(client.scopes.contains("https://graph.microsoft.com/Calendars.Read.Shared"))
        #expect(client.laterScopes == ["https://graph.microsoft.com/Calendars.Read.Shared"])
        let asked = Asked()
        client.send = { request in
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self).removingPercentEncoding ?? ""
            await asked.add(form)
            let shared = form.contains("Calendars.Read.Shared")
            let body = shared ? #"{"error":"invalid_grant","error_description":"consent required"}"# : #"{"access_token":"new","expires_in":3600}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: shared ? 400 : 200, httpVersion: nil, headerFields: nil)!)
        }
        let tokens = try await client.refresh(OAuthTokens(accessToken: "old", refreshToken: "r", expiresAt: Date()))
        #expect(tokens.accessToken == "new")
        let forms = await asked.forms
        #expect(forms.count == 2)
        #expect(forms.last?.contains("Calendars.ReadWrite") == true)
    }
}

private actor Asked {
    var forms: [String] = []
    func add(_ form: String) { forms.append(form) }
}
