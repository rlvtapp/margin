import Foundation

/// Known providers with their published server settings, so most people only type an
/// address. Anything else goes through `AutoConfig`.
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public enum SignIn: Hashable, Sendable {
        /// OAuth in the browser sheet, with an app password as the fallback.
        case oauth(OAuthProviderID)
        /// The provider requires an app-specific password; `help` explains how to make one.
        case appPassword(help: URL)
        /// The account's normal password.
        case password
        /// An API token (JMAP providers).
        case token(help: URL)
    }

    public var id: String
    public var name: String
    public var domains: [String]
    public var connection: AccountConnection
    public var signIn: SignIn
    /// One sentence shown under the sign-in fields, when something needs explaining.
    public var note: String?
    /// A short line under the name in the provider list ("Gmail and Google Workspace").
    public var detail: String?
    /// What to do at the provider before signing in, when a password has to be made or allowed.
    public var steps: [String] = []
    /// Where those steps happen, opened by a button next to them.
    public var setupURL: URL?
    /// Works only on the Mac (Proton Mail Bridge runs on the computer).
    public var macOnly = false

    /// Whether the account's own or an app password can be used. Microsoft accepts only its
    /// sign-in page.
    public var acceptsPasswords: Bool {
        if case .oauth(.microsoft) = signIn { return false }
        return true
    }

    public static func imap(
        _ id: String, _ name: String, domains: [String],
        imap: (String, Int, ConnectionSecurity), smtp: (String, Int, ConnectionSecurity),
        signIn: SignIn, note: String.LocalizationValue? = nil, detail: String.LocalizationValue? = nil,
        steps: [String.LocalizationValue] = [], setupURL: String? = nil, macOnly: Bool = false
    ) -> ProviderPreset {
        ProviderPreset(
            id: id, name: name, domains: domains,
            connection: .imap(
                incoming: ServerEndpoint(host: imap.0, port: imap.1, security: imap.2),
                outgoing: ServerEndpoint(host: smtp.0, port: smtp.1, security: smtp.2)
            ),
            signIn: signIn, note: note.map { String(localized: $0) }, detail: detail.map { String(localized: $0) },
            steps: steps.map { String(localized: $0) }, setupURL: setupURL.flatMap(URL.init(string:)), macOnly: macOnly
        )
    }
}

public enum ProviderCatalog {
    /// In the order the provider list shows them.
    public static let all: [ProviderPreset] = [
        .imap("google", "Google", domains: ["gmail.com", "googlemail.com"],
              imap: ("imap.gmail.com", 993, .tls), smtp: ("smtp.gmail.com", 465, .tls),
              signIn: .oauth(.google),
              detail: "Gmail and Google Workspace",
              steps: [
                  "Turn on 2-Step Verification for your Google account.",
                  "Open App passwords and create one called Margin.",
                  "Paste the password below.",
              ],
              setupURL: "https://myaccount.google.com/apppasswords"),
        .imap("microsoft", "Microsoft", domains: ["outlook.com", "hotmail.com", "live.com", "msn.com", "outlook.de", "hotmail.co.uk"],
              imap: ("outlook.office365.com", 993, .tls), smtp: ("smtp.office365.com", 587, .startTLS),
              signIn: .oauth(.microsoft),
              detail: "Outlook, Hotmail and Microsoft 365"),
        .imap("icloud", "iCloud Mail", domains: ["icloud.com", "me.com", "mac.com"],
              imap: ("imap.mail.me.com", 993, .tls), smtp: ("smtp.mail.me.com", 587, .startTLS),
              signIn: .appPassword(help: URL(string: "https://support.apple.com/102654")!),
              steps: [
                  "Sign in at account.apple.com.",
                  "Open Sign-In and Security, then App-Specific Passwords.",
                  "Create one called Margin and paste it below.",
              ],
              setupURL: "https://account.apple.com/account/manage/section/security"),
        .imap("yahoo", "Yahoo Mail", domains: ["yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.fr", "yahoo.de"],
              imap: ("imap.mail.yahoo.com", 993, .tls), smtp: ("smtp.mail.yahoo.com", 465, .tls),
              signIn: .appPassword(help: URL(string: "https://help.yahoo.com/kb/SLN15241.html")!),
              steps: [
                  "Open Account security in your Yahoo account.",
                  "Choose Generate app password and name it Margin.",
                  "Paste the password below.",
              ],
              setupURL: "https://login.yahoo.com/account/security"),
        ProviderPreset(
            id: "fastmail", name: "Fastmail", domains: ["fastmail.com", "fastmail.fm"],
            connection: .jmap(sessionURL: URL(string: "https://api.fastmail.com/jmap/session")!),
            signIn: .token(help: URL(string: "https://www.fastmail.help/hc/en-us/articles/5254602856719")!),
            steps: [
                String(localized: "Open Settings, then Privacy & Security, then API tokens."),
                String(localized: "Make a new token with access to Mail."),
                String(localized: "Paste the token below."),
            ],
            setupURL: URL(string: "https://app.fastmail.com/settings/security/tokens")
        ),
        .imap("proton", "Proton Mail", domains: ["proton.me", "protonmail.com", "pm.me"],
              imap: ("127.0.0.1", 1143, .plain), smtp: ("127.0.0.1", 1025, .plain),
              signIn: .password,
              steps: [
                  "Install Proton Mail Bridge on this Mac and sign in to it.",
                  "Copy the password Bridge shows for your address and paste it below.",
              ],
              setupURL: "https://proton.me/mail/bridge", macOnly: true),
        .imap("zoho", "Zoho Mail", domains: ["zoho.com", "zohomail.com"],
              imap: ("imap.zoho.com", 993, .tls), smtp: ("smtp.zoho.com", 465, .tls),
              signIn: .appPassword(help: URL(string: "https://www.zoho.com/mail/help/adminconsole/two-factor-authentication.html#alink5")!),
              note: "Accounts in the EU data center use imap.zoho.eu and smtp.zoho.eu.",
              steps: [
                  "Open My Account, then Security, then App Passwords.",
                  "Generate one called Margin.",
                  "Paste the password below.",
              ],
              setupURL: "https://accounts.zoho.com/home#security/app_password"),
        .imap("gmx", "GMX", domains: ["gmx.net", "gmx.de", "gmx.at", "gmx.ch", "gmx.com"],
              imap: ("imap.gmx.net", 993, .tls), smtp: ("mail.gmx.net", 587, .startTLS),
              signIn: .password,
              steps: [
                  "In your mailbox settings, open POP3 & IMAP and allow access.",
                  "Use your normal password below.",
              ]),
        .imap("webde", "WEB.DE", domains: ["web.de"],
              imap: ("imap.web.de", 993, .tls), smtp: ("smtp.web.de", 587, .startTLS),
              signIn: .password,
              steps: [
                  "In your mailbox settings, open POP3 & IMAP and allow access.",
                  "Use your normal password below.",
              ]),
        .imap("mailboxorg", "mailbox.org", domains: ["mailbox.org"],
              imap: ("imap.mailbox.org", 993, .tls), smtp: ("smtp.mailbox.org", 465, .tls),
              signIn: .password),
        .imap("posteo", "Posteo", domains: ["posteo.de", "posteo.net"],
              imap: ("posteo.de", 993, .tls), smtp: ("posteo.de", 465, .tls),
              signIn: .password),
        .imap("aol", "AOL Mail", domains: ["aol.com"],
              imap: ("imap.aol.com", 993, .tls), smtp: ("smtp.aol.com", 465, .tls),
              signIn: .appPassword(help: URL(string: "https://help.aol.com/articles/Create-and-manage-app-password")!),
              steps: [
                  "Open Account security in your AOL account.",
                  "Choose Generate app password and name it Margin.",
                  "Paste the password below.",
              ],
              setupURL: "https://login.aol.com/account/security"),
    ]

    public static func preset(id: String) -> ProviderPreset? { all.first { $0.id == id } }

    public static func preset(forDomain domain: String) -> ProviderPreset? {
        let lower = domain.lowercased()
        return all.first { $0.domains.contains(lower) }
    }
}
