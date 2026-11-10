import CryptoKit
import Foundation

public enum OAuthProviderID: String, Codable, Sendable, CaseIterable {
    case google, microsoft
}

/// An OAuth 2.0 public client using the authorization code flow with PKCE (RFC 7636).
/// The sign-in page opens in the system browser sheet; tokens are exchanged directly
/// with the provider and stay on the device.
public struct OAuthClient: Sendable {
    public var provider: OAuthProviderID
    public var clientID: String
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scopes: [String]
    /// Must match the redirect registered with the provider.
    public var redirectURI: String
    public var extraParameters: [String: String]

    public init(
        provider: OAuthProviderID, clientID: String, authorizeURL: URL, tokenURL: URL,
        scopes: [String], redirectURI: String, extraParameters: [String: String] = [:]
    ) {
        self.provider = provider
        self.clientID = clientID
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.extraParameters = extraParameters
    }

    /// The callback scheme the sign-in sheet listens for.
    public var callbackScheme: String { URL(string: redirectURI)?.scheme ?? "" }

    public func authorizationRequest(loginHint: String?) -> (url: URL, verifier: String, state: String) {
        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        items += extraParameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return (components.url!, verifier, state)
    }

    /// What a token request asks for. Sign-in may ask consent for several Microsoft services at
    /// once, but each Microsoft token is for one service: the first one listed, plus the plain
    /// scopes (`offline_access`, `openid`, `email`).
    var tokenScopes: [String] {
        let service = { (scope: String) -> String? in
            guard scope.hasPrefix("https://"), let url = URL(string: scope) else { return nil }
            return url.host()
        }
        guard let first = scopes.lazy.compactMap(service).first else { return scopes }
        return scopes.filter { service($0) == nil || service($0) == first }
    }

    /// Exchanges the code from the redirect for tokens.
    public func exchange(callback: URL, verifier: String, state: String) async throws -> OAuthTokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") { throw MailError.authenticationFailed(value("error_description") ?? error) }
        guard value("state") == state else { throw MailError.authenticationFailed(String(localized: "The sign-in response didn't match.")) }
        guard let code = value("code") else { throw MailError.authenticationFailed(String(localized: "No sign-in code was returned.")) }
        var form = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ]
        if provider == .microsoft { form["scope"] = tokenScopes.joined(separator: " ") }
        return try await token(form, previous: nil)
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw MailError.authenticationFailed(String(localized: "Please sign in again.")) }
        var form = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
        // Microsoft's tokens are per service, so a refresh says which service it's for.
        if provider == .microsoft { form["scope"] = tokenScopes.joined(separator: " ") }
        return try await token(form, previous: tokens)
    }

    private func token(_ form: [String: String], previous: OAuthTokens?) async throws -> OAuthTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Payload: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var error: String?
            var error_description: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let access = payload.access_token, (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MailError.authenticationFailed(payload.error_description ?? payload.error ?? "The token request failed.")
        }
        return OAuthTokens(
            accessToken: access,
            // Providers may omit the refresh token on refresh; keep the old one.
            refreshToken: payload.refresh_token ?? previous?.refreshToken,
            expiresAt: Date().addingTimeInterval(payload.expires_in ?? 3600)
        )
    }
}

public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    var isExpiring: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

/// OAuth client ids. Each build registers its own with Google and Microsoft and puts them
/// in the app's Info.plist (`MarginGoogleClientID`, `MarginMicrosoftClientID`); a provider
/// without an id offers password sign-in only.
public struct OAuthClientRegistry: Sendable {
    public var googleClientID: String?
    public var microsoftClientID: String?

    public init(googleClientID: String?, microsoftClientID: String?) {
        self.googleClientID = googleClientID?.isEmpty == false ? googleClientID : nil
        self.microsoftClientID = microsoftClientID?.isEmpty == false ? microsoftClientID : nil
    }

    public static func fromInfoPlist(_ bundle: Bundle = .main) -> OAuthClientRegistry {
        OAuthClientRegistry(
            googleClientID: bundle.object(forInfoDictionaryKey: "MarginGoogleClientID") as? String,
            microsoftClientID: bundle.object(forInfoDictionaryKey: "MarginMicrosoftClientID") as? String
        )
    }

    public func client(for provider: OAuthProviderID) -> OAuthClient? {
        switch provider {
        case .google:
            guard let id = googleClientID else { return nil }
            // Google's installed-app redirect: the reversed client id as a URL scheme.
            let scheme = id.split(separator: ".").reversed().joined(separator: ".")
            return OAuthClient(
                provider: .google, clientID: id,
                authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                scopes: ["https://mail.google.com/", "email"],
                redirectURI: "\(scheme):/oauth2redirect",
                extraParameters: ["access_type": "offline", "prompt": "consent"]
            )
        case .microsoft:
            guard let id = microsoftClientID else { return nil }
            return OAuthClient(
                provider: .microsoft, clientID: id,
                authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                scopes: [
                    "https://outlook.office.com/IMAP.AccessAsUser.All",
                    "https://outlook.office.com/SMTP.Send", "offline_access", "openid", "email",
                    // Asked for at sign-in so instant notifications on iPhone need nothing more;
                    // the token for it comes from the same sign-in (see `pushToken`).
                    "https://graph.microsoft.com/Mail.ReadBasic",
                ],
                redirectURI: "msauth.\(Bundle.main.bundleIdentifier ?? "app")://auth"
            )
        }
    }
}

/// Access beyond mail, asked for only when someone turns it on, so signing in stays simple.
public enum APIAccess: String, Codable, Sendable, CaseIterable {
    /// Contacts and the people someone works with.
    case contacts
    /// Creating meetings, and who's free when.
    case calendar
    /// The organization's meeting rooms. Some organizations need an admin to allow it; on Google
    /// only Workspace admins can list them.
    case rooms
    /// The out-of-office reply.
    case autoReply

    func scopes(for provider: OAuthProviderID) -> [String] {
        switch (provider, self) {
        case (.microsoft, .contacts):
            // User.ReadBasic.All: colleagues by name in the work directory (no admin consent needed).
            ["https://graph.microsoft.com/Contacts.Read", "https://graph.microsoft.com/People.Read",
             "https://graph.microsoft.com/User.ReadBasic.All"]
        case (.microsoft, .calendar):
            ["https://graph.microsoft.com/Calendars.ReadWrite"]
        case (.microsoft, .rooms):
            ["https://graph.microsoft.com/Place.Read.All"]
        case (.google, .contacts):
            ["https://www.googleapis.com/auth/contacts.readonly", "https://www.googleapis.com/auth/contacts.other.readonly"]
        case (.google, .calendar):
            ["https://www.googleapis.com/auth/calendar.events", "https://www.googleapis.com/auth/calendar.freebusy"]
        case (.google, .rooms):
            ["https://www.googleapis.com/auth/admin.directory.resource.calendar.readonly"]
        case (.microsoft, .autoReply):
            ["https://graph.microsoft.com/MailboxSettings.ReadWrite"]
        case (.google, .autoReply):
            ["https://www.googleapis.com/auth/gmail.settings.basic"]
        }
    }

    /// What each provider offers.
    public static func offered(by provider: OAuthProviderID) -> [APIAccess] {
        [.contacts, .calendar, .rooms, .autoReply]
    }
}

/// Tokens for the APIs beyond mail, with what they were granted for. Kept in the Keychain apart
/// from the mail tokens.
public struct APITokens: Codable, Sendable {
    public var tokens: OAuthTokens
    public var access: Set<APIAccess>

    public init(tokens: OAuthTokens, access: Set<APIAccess>) {
        self.tokens = tokens
        self.access = access
    }
}

extension OAuthClientRegistry {
    /// A client for the APIs beyond mail, asking for `access`.
    public func client(for provider: OAuthProviderID, access: Set<APIAccess>) -> OAuthClient? {
        guard var client = client(for: provider) else { return nil }
        let scopes = APIAccess.allCases.filter(access.contains).flatMap { $0.scopes(for: provider) }
        client.scopes = scopes + (provider == .microsoft ? ["offline_access"] : [])
        if provider == .google { client.extraParameters["include_granted_scopes"] = "true" }
        return client
    }
}

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum FormEncoding {
    static func encode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
