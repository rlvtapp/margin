# Margin

A free, open-source mail app for the Mac. It's fast and keyboard-first, and it connects directly to your mail provider.

- **No account and no middleman.** Margin talks to your provider straight from your device, over IMAP and SMTP or JMAP. No server of ours sits in between, and nothing is tracked.
- **All your mailboxes in one window.** Each mailbox has its own picture in the rail on the left, with its unread count. "All" combines every mailbox: one Inbox, Starred, Drafts, Sent, Archive, Junk and Trash, and each conversation shows which mailbox it's in.
- **Keyboard first.** `J`/`K` to move, `E` to mark done, `R` to reply, `⌘K` for every command, `?` for the full list. Shortcuts are printed next to the actions, so you learn them as you go.
- **A calmer inbox.** The inbox is split on your device into People, Updates and Newsletters, using standard headers. No message content leaves the device for this.
- **Open standards.** Google, Microsoft, iCloud, Yahoo, Fastmail, Zoho, GMX, AOL, Proton Mail (through Bridge) and any standard IMAP or JMAP server.
- **An assistant you choose.** Summaries, suggested labels and reply drafts from Apple's on-device model by default, or from Ollama, LM Studio, Claude, ChatGPT or any OpenAI-compatible server with your own key. It only runs when you ask.
- **Talk to your mail from AI apps.** An optional MCP connection lets Claude, ChatGPT and other MCP apps search and read your mail through Margin, on this Mac only. Changing and sending need their own switches.

Licensed under [Apache 2.0](LICENSE).

## Status

Early. What works today:

| Area | State |
| --- | --- |
| Offline and search | Mail kept on the Mac in SQLite with a full-text index; opens instantly and works offline; Return searches saved mail and every server |
| Folders and drafts | Create, rename, delete folders; Move to (V); closing a message saves it to Drafts; Edit draft |
| Writing | Formatting (bold, italic, underline, lists, links) sent as HTML alongside plain text; templates with fill-ins |
| Calendar | Invitations show with Join, Add to Calendar, and Accept / Maybe / Decline sent back as standard replies |
| Make it yours | Light or dark, accent colour, one- or three-line rows, side-by-side or wide list, change any shortcut |
| Backup | Export and restore settings, mailboxes, labels, templates; password-encrypted backups can carry passwords too |
| Reading (IMAP, JMAP) | Folders, latest 200 conversations per folder, threading, HTML mail in a locked-down view (no scripts, remote pictures and trackers blocked until you allow them), attachment names |
| Triage | Done (archive), star, read/unread, trash with Undo; snooze; select several with ⌘/⇧-click, X or ⌘A for bulk actions; Unread, Starred and Attachments filters |
| Clean-up | One-click unsubscribe (RFC 8058, mail or web fallback), archive everything from a sender, copy sign-in codes |
| Follow-ups | Waiting for reply (sent mail nobody answered after 2–7 days), one-click follow-up |
| Sending (SMTP, JMAP) | Plain-text messages with attachments, signatures per mailbox, undo send (5–30 s), send later, forgotten-attachment warning, a copy filed in Sent |
| Reading | Open, drag out or save attachments; translation; text size 80–200%; plain-text option |
| Notifications | New mail from people (or all, or none), checked every few minutes |
| Sign-in | Passwords and app passwords (Keychain), OAuth 2.0 with PKCE for Google and Microsoft (bring your own client id), JMAP API tokens |
| Setup | Built-in provider list, JMAP discovery, autoconfig files, the public ISP database |
| Multiple accounts | Account rail, All inboxes, per-account folders, send from any account |
| Assistant | Ask questions across your mail with sources, summaries, labels, drafts and rewrites; on-device, local (Ollama, LM Studio) or hosted (Claude, ChatGPT, OpenAI-compatible) |
| Connections | MCP server on 127.0.0.1 (HTTP and stdio), read-only by default |
| Platforms | macOS 15+. The engine and UI packages also build for iOS and iPadOS, but there's no app target for them yet |

The protocol clients are tested against scripted local servers (`swift test`). They haven't been run against every provider yet; [docs/providers.md](docs/providers.md) tracks which ones have been tried.

See [docs/intelligence.md](docs/intelligence.md) for the assistant and connections, [docs/localization.md](docs/localization.md) for languages, [docs/new-mail.md](docs/new-mail.md) for how new mail arrives without a server, [docs/siri.md](docs/siri.md) for Siri and sign-in codes, [docs/watch.md](docs/watch.md) for Apple Watch, [docs/app-icon.md](docs/app-icon.md) for the app icon, [docs/home.md](docs/home.md) for Home and sorting, [docs/calendar.md](docs/calendar.md) for meetings from invitations, [docs/alerts.md](docs/alerts.md) for alerts and email links, [docs/devices.md](docs/devices.md) for backups and linking devices, [docs/website.md](docs/website.md) for the homepage and privacy policy, [docs/release.md](docs/release.md) for production builds and deploying, [docs/google-verification.md](docs/google-verification.md) for Google sign-in approval, and [docs/roadmap.md](docs/roadmap.md) for what's next.

## Build

Needs Xcode 26 or later.

```bash
open Apps/Margin.xcodeproj
```

Choose the **Margin** scheme and run. On first launch you'll see two sample mailboxes, so you can try everything without signing in. Add a real account with the **+** block.

Run the engine tests:

```bash
swift test
```

To turn on Google or Microsoft sign-in, register your own OAuth client and put its id in `Apps/Config/Margin.local.xcconfig`. See [docs/oauth.md](docs/oauth.md). Without one, those providers use app passwords.

## Layout

```
Package.swift          MailCore + MailUI, shared by every platform
Sources/MailCore/      The engine: IMAP, SMTP, JMAP, MIME, OAuth, Keychain, setup, triage
Sources/MailUI/        SwiftUI: rail, sidebar, list, reader, compose, command palette
Tests/MailCoreTests/   Parsers, MIME, threading, and live protocol tests against local servers
Apps/                  Thin app targets (macOS today)
docs/                  Architecture, providers, OAuth, languages, roadmap
scripts/               App icon renderer
```

[docs/architecture.md](docs/architecture.md) explains how the parts fit together.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
