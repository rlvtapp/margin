# Release: production builds and deploying

How to run Margin the way people will get it, and how to put the website and the push relay
online. Google sign-in has its own checklist in [google-verification.md](google-verification.md).

## Production settings

The production values live in `Apps/Config/Margin.local.xcconfig`, which git ignores. It replaces
anything in `Margin.xcconfig`.

| Setting | Now | Meaning |
| --- | --- | --- |
| `MARGIN_BUNDLE_ID` | `dev.margin.Margin` | Decide the App Store id before registering clients; changing it later means new clients, a new iCloud container, and installed copies start empty. |
| `MARGIN_GOOGLE_CLIENT_ID` | empty | Stays empty until Google approves the app. Gmail signs in with an app password meanwhile. |
| `MARGIN_MICROSOFT_CLIENT_ID` | empty, to fill in | From the Entra registration below. Without it Outlook and Microsoft 365 accounts can't sign in at all. |
| `MARGIN_PUSH_RELAY_URL` | empty | `https:/$()/push.margin.relevate.app` once the relay runs (`//` starts a comment in xcconfig files). |
| `MARGIN_GMAIL_PUSH_TOPIC` | empty | Only with Google sign-in. |

## Running the production build

Pick the **Margin (Release)** scheme (Mac) or **Margin iOS (Release)** (iPhone and iPad) and run.
These build the Release configuration, so they behave like the shipped app: optimised, no debug
code. On iPhone, push uses Apple's sandbox for any build Xcode installs and production for
TestFlight and the App Store; the app reads this from its signing profile.

What to test:

- **Microsoft**: an Outlook.com account and, if possible, a Microsoft 365 work account. Sign in,
  read, send, delete, then turn on contacts, calendar and out-of-office in the account settings.
- **App passwords**: Gmail, iCloud, Yahoo and Fastmail. The support page has the steps.

## Microsoft sign-in (Entra app registration)

1. Go to entra.microsoft.com, App registrations, New registration. Sign in with the company's
   Microsoft account.
2. Name: **Margin**. Supported account types: **Accounts in any organizational directory and
   personal Microsoft accounts**.
3. Redirect URI: platform **Public client/native (mobile & desktop)**, value
   `msauth.dev.margin.Margin://auth` (`msauth.` plus the bundle id, plus `://auth`).
4. Copy the **Application (client) ID** into `MARGIN_MICROSOFT_CLIENT_ID`.
5. Under Authentication, set **Allow public client flows** to Yes. There's no client secret.
6. Under API permissions, add these delegated permissions so the consent screen lists them up front:
   - Office 365 Exchange Online: `IMAP.AccessAsUser.All`, `SMTP.Send`
   - Microsoft Graph: `offline_access`, `email`, `Mail.ReadBasic` (push), `Contacts.Read`,
     `People.Read`, `Calendars.ReadWrite`, `MailboxSettings.ReadWrite`, `Place.Read.All` (rooms;
     needs an admin in work accounts)
7. Under Branding & properties, add the homepage, terms and privacy links on margin.relevate.app,
   and the logo.
8. **Publisher verification** (Branding & properties → verify publisher) with the company's free
   Microsoft partner id. Without it, many work accounts can't approve Margin themselves and see
   "unverified". Personal Outlook accounts work without it.

Microsoft has no paid review like Google's.

## Apple

This Mac only has a free Personal Team. Push notifications, iCloud sync, TestFlight and the App
Store all need the company's paid Apple Developer Program membership ($99 a year):

- Add the company team in Xcode (Settings → Accounts) and choose it for the three targets.
- Register the bundle id with Push Notifications and iCloud (container `iCloud.<bundle id>`).
- Create an APNs key for the relay (Keys → Apple Push Notifications service).
- Mac builds shared outside the App Store need a Developer ID certificate and notarisation.

## Website (margin.relevate.app)

On Cloudflare Workers, with the custom domain in the relevate.app zone set in
`site/wrangler.jsonc`. Before the first deploy, make sure `margin@relevate.app` exists, since
every page shows it.

```sh
cd site
pnpm install --ignore-workspace
pnpm exec wrangler login
pnpm run deploy
```

## Push relay (push.margin.relevate.app)

On Fly.io in Frankfurt, with `relay/fly.toml`. One-time setup:

```sh
cd relay
fly apps create margin-relay
fly volumes create relay_data --region fra --size 1
fly secrets set APNS_KEY_ID=… APNS_TEAM_ID=… GMAIL_PUSH_TOKEN=$(openssl rand -hex 32)
fly secrets set APNS_KEY="$(cat ~/keys/AuthKey_XXXXXXXXXX.p8)"
fly deploy
fly certs add push.margin.relevate.app
```

Then add the DNS records `fly certs add` prints in the relevate.app zone on Cloudflare (DNS
only, not proxied), check `https://push.margin.relevate.app/healthz` answers, and set
`MARGIN_PUSH_RELAY_URL`.

Later deploys are just `fly deploy`.
