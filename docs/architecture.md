# Architecture

Margin has three layers. Each layer only knows about the one below it.

```
Apps/macOS (later Apps/iOS)   Window, menus, app lifecycle. Thin.
        │
Sources/MailUI                SwiftUI views and MailModel (state for all accounts)
        │
Sources/MailCore              Protocols, parsing, accounts, secrets. No UI, no AppKit.
        │
mail servers                  Each account's own IMAP/SMTP or JMAP server, reached directly
```

MailCore uses only Foundation, Security and CryptoKit, so it runs unchanged on macOS, iOS and iPadOS. MailUI uses SwiftUI and keeps platform-specific code behind `#if os(macOS)`. Both build for iOS today (`xcodebuild -scheme Margin-Package -destination 'generic/platform=iOS Simulator' build`).

## Direct connections

Every account has a `MailProvider` (an actor). All of them connect from the device to the account's own servers:

- `IMAPProvider` reads with IMAP4rev1/rev2 (RFC 3501, RFC 9051) and sends with SMTP submission (RFC 6409).
- `JMAPProvider` does both over HTTPS (RFC 8620, RFC 8621).
- `SampleProvider` keeps made-up mail in memory, so you can try the app without signing in.

`LineConnection` is the TCP transport for IMAP and SMTP. It's built on `URLSessionStreamTask` because that can upgrade a live connection to TLS, which STARTTLS needs. Unencrypted connections are refused unless the host is this machine (which Proton Mail Bridge needs).

The only third-party request the app makes is during setup. For a domain it doesn't know, it may ask the public ISP database for that domain's server settings. It sends the domain only, never the address.

## Accounts and secrets

`AccountStore` saves the account list (names, hosts, ports, colour) as JSON in Application Support. Passwords, app passwords, API tokens and OAuth tokens are stored only in the Keychain, under the account's id, and are readable on this device only. `KeychainCredentials` refreshes OAuth tokens when they're about to expire.

## State: MailModel

`MailModel` (in MailUI, main actor) holds every account's folders and inbox at once:

- `inboxes[accountID]` and `mailboxes[accountID]` are loaded in parallel on refresh.
- Thread ids only need to be unique within one account, so the model prefixes them with the account id (`MailModel.tag`) and sets `thread.accountID`.
- `Place` says what the list shows: an inbox (one account or all of them, optionally one split), Starred, one account's folder, or `.combined(role)`: the same kind of folder (Sent, Drafts, Archive, Junk, Trash) fetched from every account in parallel and merged by date. Archive falls back to an account's all-mail folder.
- Actions are applied locally first, so the list responds straight away, and then sent to each thread's own account.
- Done and Trash wait 5 seconds before they reach the server. Undo just cancels the wait. This works the same on every protocol, whereas reversing an IMAP move afterwards would mean guessing the messages' new ids. Anything still waiting is sent when the app quits.

## Triage on the device

- `Threader` groups messages by `In-Reply-To` and `References` first. A reply whose parent wasn't fetched joins by its normalised subject.
- `InboxSplit` sorts mail into People, Updates and Newsletters from standard headers: `List-Id`, `List-Unsubscribe`, `Precedence`, `Auto-Submitted`, and no-reply style senders.
- `SearchQuery` searches the loaded mail with `from:`, `to:`, `subject:`, `is:unread`, `is:starred`, `has:attachment`, `in:people` and quoted phrases.

## HTML mail

HTML mail is shown in a locked-down WebKit view (`HTMLMessageView`), the one place the app draws web content, because HTML mail *is* web content. Several locks are layered:

- `HTMLSanitizer` (MailCore) removes scripts, frames, embeds, forms, event handlers, `javascript:` links, `<base>` and meta refresh. It also counts remote resources and likely tracking pixels.
- WebKit runs with page scripts off, a non-persistent data store, and a content rule that blocks every load except `data:`, `about:` and `blob:`. If that rule can't be installed, the HTML isn't shown at all.
- Remote pictures stay off until you choose "Load pictures" (this message) or "Always for this sender" (kept on this device). Loading them tells the sender you opened the mail, which is why it's a choice.
- Links open in the browser. `mailto:` links open Margin's composer, from the account the mail arrived in.
- In dark mode, mail that declares dark support (`color-scheme`, `prefers-color-scheme`) renders dark. Anything else sits on a white sheet, so a layout designed for light backgrounds stays readable.

- Settings → Reading → "Show mail as" sets plain text instead for everyone who'd rather have no web view. Plain text uses the mail's own text part, or text taken from the HTML when there is none. Each message can still switch with "Show as plain text" / "Show original layout".

`cid:` inline images aren't fetched yet; see the roadmap.

## Saved mail and search

`MailCache` (MailCore/Store) is a SQLite database with an FTS5 full-text index. It holds folders, the latest conversations per folder, the bodies you've opened, and attachments up to 2 MB. At launch the window fills from it before any server answers. When a server can't be reached, the saved mail stays and the sidebar says so. Pressing Return in the search field searches saved mail at once, then asks every server (IMAP `UID SEARCH TEXT`, JMAP `Email/query` with a text filter) for older mail, and merges the results by Message-ID.

## Everyday tools kept on the device

Snoozes (`snoozes.json`) and the outbox (`outbox.json`) are JSON files in Application Support. The app does the work, so no server is needed:

- **The clock.** A clock in `MailModel+Timing.swift` ticks every 20 seconds. It wakes due snoozes and sends due scheduled messages, and checks for new mail about every 3 minutes, posting notifications for new mail from people. Scheduled mail only goes out while Margin is running.
- **Undo send.** Sending holds the message in memory for the undo delay before it reaches SMTP or JMAP.
- **Waiting for reply.** Sent mail where you wrote last counts as waiting when no inbox message answers it, by `In-Reply-To`/`References`, or by the same subject from a recipient.
- **Unsubscribe.** Uses RFC 8058 one-click (a cookie-less POST) when the sender supports it, otherwise the list's mail address, otherwise its web page.

## Commands and keyboard

`MailCommand.all(for:)` is the single list of commands. The command palette (⌘K) shows it, the shortcuts sheet (?) documents it, and the single-key handler runs it. A new command only needs adding there. Single keys only act while the conversation list has focus, so they never fire while you're typing.

## Design

The look is called paper and ink: one neutral scale per appearance, and the system font at regular and medium weights only. Colour is used only where it means something: each account's colour, the three parts of the inbox, a steady colour per sender, and a blue unread mark. All tokens live in `Sources/MailUI/Design/Theme.swift`; views never hard-code colours.

## Checking the UI without screen recording

`-snapshot <file.png>` launches the app with the sample mailboxes, renders the window to a PNG and quits. Add `-appearance light|dark`, `-snapshot-palette`, `-snapshot-compose`, `-snapshot-mailbox 0`, `-snapshot-combined sent` or `-snapshot-select "Issue 212"`. Web content is drawn in another process, so snapshot mode paints each web view's own snapshot over its frame. A sandboxed build can only write inside its container, so build without the sandbox entitlement for snapshots:

```bash
cd Apps && xcodebuild -scheme Margin -derivedDataPath ../.build/xcode-snapshot CODE_SIGN_ENTITLEMENTS= MARGIN_BUNDLE_ID=dev.margin.Margin.snapshot build
../.build/xcode-snapshot/Build/Products/Debug/Margin.app/Contents/MacOS/Margin -snapshot /tmp/margin.png -appearance dark
```
