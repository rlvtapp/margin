# Providers

Adding an account starts with a list of providers. Picking one shows its few setup steps (where to make an app password, with a button that opens that page) or, for Google and Microsoft, a single sign-in button. Microsoft accepts only its sign-in page, so it offers no password field; Google offers an app password as a fallback. Proton Mail is listed on the Mac only, since Bridge runs there. "Other" asks for an address and finds the servers as described below. The steps and links live with each provider in `ProviderCatalog.swift`. The provider logos are Simple Icons' single-colour marks (CC0), kept as `provider-<id>` images in both apps' asset catalogs and drawn in each brand's colour by `ProviderMark`; Microsoft's four squares are drawn in code, and providers without a mark show their initial.

Margin uses each provider's published, standard access: IMAP with SMTP, or JMAP. The built-in list is in `Sources/MailCore/Setup/ProviderCatalog.swift`. Any other domain goes through `AutoConfig`:

1. the built-in list (matched by domain),
2. JMAP discovery at `https://<domain>/.well-known/jmap`,
3. the domain's own autoconfig file (`autoconfig.<domain>` or `/.well-known/autoconfig/`),
4. the public ISP database, asked about the domain only,
5. otherwise a guess (`imap.<domain>:993`, `smtp.<domain>:465`), with the server fields open so you can correct it.

| Provider | Protocol | Sign-in | Tried against the real service |
| --- | --- | --- | --- |
| Google (Gmail, Workspace) | IMAP + SMTP | OAuth (needs a client id, see [oauth.md](oauth.md)) or an app password | Not yet |
| Microsoft (Outlook.com, Microsoft 365) | IMAP + SMTP (STARTTLS) | OAuth (needs a client id). Microsoft no longer accepts passwords | Not yet |
| iCloud Mail | IMAP + SMTP (STARTTLS) | App-specific password | Not yet |
| Yahoo Mail, AOL | IMAP + SMTP | App password | Not yet |
| Fastmail | JMAP | API token | Not yet |
| Zoho Mail | IMAP + SMTP | App password (EU accounts: change hosts to `.eu`) | Not yet |
| GMX | IMAP + SMTP (STARTTLS) | Password, once IMAP is turned on in GMX settings | Not yet |
| WEB.DE | IMAP + SMTP (STARTTLS) | Password, once IMAP is turned on in WEB.DE settings | Not yet |
| mailbox.org | IMAP + SMTP | Password | Not yet |
| Posteo | IMAP + SMTP | Password | Not yet |
| Proton Mail | IMAP + SMTP through Proton Mail Bridge on `127.0.0.1` | The password Bridge shows | Not yet |
| Any IMAP server | IMAP + SMTP | Password | Tested against scripted local servers |
| Any JMAP server | JMAP | Token or password | Not yet |

When you try a provider, please update the last column in a pull request, noting what worked and what didn't.

## Behaviour per provider

- **Done** moves conversations to the account's Archive folder (the `\Archive` special-use folder). If there isn't one, it uses the all-mail folder (`\All`, which is what Gmail has). On JMAP it removes the inbox from the message's mailboxes and adds the archive.
- **Sent copies.** SMTP doesn't keep a copy, so after sending Margin appends one to Sent. The exceptions are Gmail and Microsoft, which file it themselves. JMAP files it in the same request.
- **MOVE.** Uses RFC 6851 `MOVE` when the server offers it. Otherwise it copies, marks the original deleted and expunges just those messages with `UID EXPUNGE` (RFC 4315).

## Mailbox pictures

A mailbox on its own domain shows that company's logo: `DomainLogos` (MailCore/Setup) reads the
domain's home page for `apple-touch-icon` and icon links, falls back to `/apple-touch-icon.png`,
and keeps the first bitmap at least 48 pixels square in Application Support/Margin/Logos. Only
the domain's own website is asked, at most once a week when nothing was found. Free-mail domains
(the providers above, plus common ISP domains) keep the letter. Every mailbox also carries its
provider's mark in the corner, worked out from the provider chosen at setup or, failing that, the
servers it uses (`ProviderCatalog.preset(for:)`), so a Microsoft 365 address on its own domain
still shows Microsoft. The privacy policy (site/src/routes/privacy.tsx) mentions the logo fetch.
