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
