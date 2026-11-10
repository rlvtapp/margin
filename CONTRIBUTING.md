# Contributing

Thanks for helping. A few ground rules keep Margin what it is:

1. **Direct connections only.** No feature may send mail, addresses or credentials to a server other than the account's own mail server. Setup lookups ask about domains, never addresses.
2. **Open standards.** Add providers through IMAP, SMTP, JMAP, CardDAV and CalDAV, not through private APIs.
3. **The keyboard and the mouse are equal.** Every action is a `MailCommand`, so it shows in ⌘K and the shortcut list.
4. **No layout jumps.** Reserve space for counts, badges and button labels that change.
5. **Colour means something.** It marks an account, a part of the inbox, a person, or unread. Take colours from `Theme.swift`, never hard-code them.

## Working on it

- `swift test` runs the engine tests, including live IMAP and SMTP exchanges against scripted local servers. Please add a test with every protocol change.
- Keep MailCore free of UI frameworks so it keeps building for iOS.
- Keep files focused, roughly 300 lines at most. Write comments that explain *why*: protocol quirks, RFC references, offline behaviour.
- Check UI changes in light and dark mode. The `-snapshot` mode in [docs/architecture.md](docs/architecture.md) renders both without needing screen recording.

By contributing you agree that your work is licensed under Apache 2.0.
