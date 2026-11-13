# OAuth sign-in (Google and Microsoft)

Google and Microsoft sign in through OAuth 2.0 (authorization code with PKCE). The sign-in page opens in the system's web authentication sheet. The tokens are exchanged directly with the provider and stored in the Keychain. Margin sends them to IMAP and SMTP with SASL `XOAUTH2`, or `OAUTHBEARER` where a server offers only that.

OAuth client ids belong to whoever distributes a build. This repository doesn't ship one. Without an id, Google and Microsoft accounts are offered app passwords instead (Microsoft accounts then can't sign in, because Microsoft has turned off password access).

## Where the ids go

Create `Apps/Config/Margin.local.xcconfig`. Git ignores it.

```
MARGIN_BUNDLE_ID = com.yourdomain.Margin
MARGIN_GOOGLE_CLIENT_ID = 1234567890-abc.apps.googleusercontent.com
MARGIN_MICROSOFT_CLIENT_ID = 00000000-0000-0000-0000-000000000000
```

The build copies them into Info.plist (`MarginGoogleClientID`, `MarginMicrosoftClientID`), and `OAuthClientRegistry.fromInfoPlist()` reads them from there.

## Google

1. In Google Cloud Console, create an OAuth client of type **iOS** (this type also works for macOS apps). Set its bundle id to your `MARGIN_BUNDLE_ID`.
2. The redirect is the reversed client id, `com.googleusercontent.apps.1234567890-abc:/oauth2redirect`. Margin builds it from the id.
3. Scopes: `https://mail.google.com/` and `email`.
4. `https://mail.google.com/` is a restricted scope. Testing with up to 100 listed test users works right away. A public release needs Google's verification and a yearly security assessment.

## Microsoft

1. In Microsoft Entra, register an app for **personal Microsoft accounts and any organisational directory**.
2. Add a **Mobile and desktop** platform with the redirect URI `msauth.<your bundle id>://auth`.
3. Add these delegated permissions: `IMAP.AccessAsUser.All` and `SMTP.Send` (Office 365 Exchange Online), plus `offline_access` and `email`.
4. Microsoft 365 tenants may need an administrator to allow the app.

## Refreshing tokens without flooding the provider

Access tokens last about an hour. When one runs out, everything that needs it (each mail
connection, contacts, calendar, pictures, push) used to ask for a new one at the same moment,
and to ask again straight after a failure. Microsoft reads that as a loop, answers
`AADSTS50196` ("client request loop") and refuses every sign-in for the account for a while,
which showed as "Sign-in was refused" on Outlook mailboxes and as "Offline" on a phone using
the same account.

`KeychainCredentials.refreshed(_:key:with:)` is now the one way to refresh:

- **One request.** Callers that need the same new token (same account and kind) wait for the
  one request already out.
- **A pause after failure.** A failed refresh isn't repeated straight away; callers get the
  same error back until the pause is over: 15 seconds for no connection, a minute for anything
  unknown, six minutes for a request loop (shown as "Microsoft asked Margin to wait a few
  minutes…"), fifteen for a sign-in that's no longer valid.
- **Signing in again lifts the pause** (`forgetPauses(for:)`).
- **The newest refresh token is the one kept.** Microsoft sends a new refresh token with every
  token it hands out, also the ones fetched for notifications and the profile, and may stop
  honouring older ones (`AADSTS70000`, "scopes … unauthorized or expired"). Whichever request
  brought it, the mail sign-in in the Keychain takes the newest (`keepNewestRefreshToken`).
- **When the sign-in really is spent**, the mailbox offers "Sign in again" (see Architecture →
  Signing in again); nothing has to be removed.

When every account fails to refresh, the list's status line says "Offline" only if the network
was the reason; a refused sign-in says "Couldn't sign in" (`MailModel.refusalNote`), and each
mailbox shows what its server said.

People's pictures are fetched two at a time (`ContactPictures`), and a lookup that couldn't be
made isn't remembered as "has no picture".

Tests: `Tests/MailCoreTests/TokenRefreshTests.swift`.
