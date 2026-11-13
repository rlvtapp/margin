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

## Staying connected

An IMAP mailbox keeps one connection open between requests (and a second that waits for new mail). Connections die without telling anyone: the Mac sleeps, the phone puts the app away, the network changes, the server hangs up after a quiet while. Four things keep that from ever showing as a stuck mailbox:

- **A dead connection is never kept, and the request is done again.** `IMAPProvider.reliably` wraps reading, searching, flag changes and moves: when the connection in use turns out to be dead ("Socket is not connected", a timeout, "connection closed"), it's dropped and the work is done once more on a new one. Only a brand-new connection failing is reported. Work that mustn't happen twice (saving a draft, filing a sent copy, making or renaming a folder) checks the line first with NOOP instead (`checkedConnection`).
- **Reconnecting when the world changes.** `MailModel.reconnect()` closes every connection and fetches fresh when the network comes back or changes (`NWPathMonitor`), when the Mac wakes, and when the iPhone or iPad app comes back from the background.
- **Trying again by itself.** An account that couldn't be reached is retried alone after 20 seconds, then 40, 80, and from there with the regular three-minute refresh (`retryUnreachable`, `retryDelay(after:)`).
- **Said calmly.** A connection problem (`MailModel.isUnreachable`) isn't an account problem: the sidebar says "Can't reach the server right now. Margin keeps trying." in quiet ink with Try Again, the system's own error text is in its tooltip, saved mail stays on screen, and the account column shows no red dot. Red is for trouble that needs you, like a refused sign-in.

Tests: `Tests/MailCoreTests/ReconnectTests.swift` (a real socket to a server that hangs up), `UnreachableAccountTests` in `Tests/MailUITests/AskFactsTests.swift`.

## Opening a mail quickly

A mail opened before is on the device and shows at once. A mail opened for the first time used to be slow for four reasons, each now dealt with:

- **Its own connection.** The first connection does one folder operation at a time (the three-minute refresh, the Sent check, reading ahead, scanning for invitations), and a click stood in that line. The mail on screen now has a connection of its own (`IMAPProvider.onReader`, a third beside the main one and the one waiting for new mail). A server that won't give one is asked on the first connection instead, and that isn't tried again for ten minutes.
- **Text before files.** `MailProvider.openedBody(of:)` fetches the first 200,000 bytes. Most mail is smaller and is whole in that one request. When it isn't, and the text is all there with a file begun after it (`IMAPProvider.readableStart`), the text is shown at once with "Loading attachments…" (`MessageBody.isPartial`, never saved), and the whole message replaces it when it arrives. A start that cuts through the text itself isn't shown half-finished; the whole is fetched.
- **A conversation in one request.** `MailProvider.bodies(of:)` asks for every missing message of a folder in a single fetch, instead of one round trip each.
- **At launch, from this device first.** The conversation that's open reads its saved text straight after saved mail is loaded (`start()`), not after the sync and every mailbox's refresh: the system log showed sixteen seconds of "Loading…" at launch for a mail that was on the Mac, while a click afterwards took a third of a second.
- **Reading ahead where you are.** The top 20 conversations of the inbox are fetched ahead as before (12 until now), and while one conversation is open, the two below it and the one above are fetched too (`MailModel.readAhead(around:)`); choosing another starts that over.

Tests: `Tests/MailCoreTests/OpenedMailTests.swift`.

Opening never waits on Sent: the saved replies and the server's are read alongside, and the
conversation is filled in again if they add a message. Text saved ahead of time (see "Older mail
on this device") makes most first opens a read from disk.

## Many mailboxes at once

Work that grew with the number of mailboxes, found with six full ones (`Tests/MailUITests/ManyAccountsPerfTests.swift`) and a sample of the running app:

- **New mail refreshes its own mailbox.** A mailbox that reports new mail is fetched alone (`reload(only:)`); it used to fetch every mailbox again and redo all the work that follows a full refresh.
- **Sent folders take turns.** One mailbox's Sent is read per tick, the one read longest ago, once that's two minutes back (`dueForSentCheck`), instead of all of them in a row.
- **"Needs you" is cheap.** The account column asks for it on every redraw. Its cache key was worked out once per conversation and walked through every labelled conversation each time; it's now worked out once per count, from a revision number the label store keeps (`LabelStore.revision`).
- **System search is only told about changes.** The top 300 conversations go to Spotlight and Siri when they've changed, not after every refresh.

## Mailboxes of any size

A mailbox can hold two hundred conversations or a million; the app does the same work either way. Three things make that so.

**Memory holds a part, saved mail holds the rest.** Each inbox is in memory as its newest page (`MailModel.listPage`, 200 conversations) plus whatever has been scrolled to since. Everything else is in the saved-mail database and on the server. Holding every conversation in memory was measured and set aside: it costs about 1.7 KB a conversation, so a million would be 1.7 GB before a single mail is opened.

- The list shows `listWindow` rows and ends in a row that isn't a conversation (`ListEndRow`, Mac and iPhone/iPad alike). When that row comes on screen, `listReachedEnd()` shows the next 200 of what's loaded, and once everything loaded is on screen, asks for older mail (`loadOlderInboxes`): the next page from saved mail first, which shows at once, then the server's own answer for a window 200 larger. What came is shown without waiting for the last row to come on screen again. Folders (Sent, Archive, a label, the combined ones) grow the same way (`folderLimit`).
- Mailboxes shown together (All inboxes, Home) are read down to where the first of them runs out of loaded mail (`ShelfReader.init(shelves:open:)`). Below that point a mailbox with older mail still on its server would have gaps, and its mail would later appear in the middle of the list. So older mail is fetched for the mailbox whose loaded mail ends first, together with any that would be next before its new page is used up, and the list only ever grows at its end.
- Only an inbox or a folder shown whole fetches older mail at its end. A list that picks conversations out (Starred, Snoozed, VIPs, a group, a quick filter, a search typed in the list) shows everything that's loaded and stops there; searching (Return) asks the servers, as before.
- Snoozed doesn't depend on what's loaded: a copy of each snoozed conversation (without message text) is saved in `snoozed-conversations.json` when it's snoozed, also for ones snoozed earlier the next time they're in memory, and dropped when it wakes or is unsnoozed. The page shows those copies with the inbox's own, newer ones where they're loaded (`MailModel+SnoozedCopies.swift`), so it's there at once instead of after a refresh.
- Waiting for reply is worked out from the Sent mail saved on this device, shown at once and kept for the next visit; the server's Sent is checked at most every two minutes (`waitingThreads(_:refresh:)`, `loadSentMail`).
- Leaving a list lets its older mail go (`forgetOlderMail`): every list starts from its newest page, so memory and the work of a refresh follow where you are, not where you've been.
- The header's "1,240 conversations, 9 unread" counts everything loaded for the place, not the rows shown; Select All selects all of it (`wholeList`).

**One conversation changing touches one conversation.** Each mailbox's inbox is an `InboxShelf`: the conversations newest first, and beside each a byte of facts (unread, starred, has a file, which part of the inbox) and its date, with unread counts kept as conversations change.

- A read mark, a star, Done, Trash and Undo find their conversations by date (a binary search) and change those (`changeInInboxes`, `removeFromInboxes`, `restoreToInboxes`). Undo puts back what was taken out; mail that arrived in between stays.
- Views don't watch the shelves themselves but two numbers: `inboxRevision` (any change) and `inboxOrder` (conversations came, went or changed places). What only depends on which conversations there are isn't worked out again for a read mark.
- The rows on screen are the newest few that pass, read straight off the shelves across mailboxes (`ShelfReader.newest`), never by merging every mailbox and sorting. When deciding takes a look at each conversation (a search in the list, a group, snoozes, pins), that's done once per change of `inboxOrder` and kept as places in the shelves (`PlaceIndex`).
- Unread counts are read off the shelves. Snoozed, VIP and labelled conversations, and how many conversations each sender started, are found once and kept the same way (`MailModel+Located.swift`).
- "Needs you" looks at mail from the last three weeks (`noteHorizon`: a reply is owed that long, and a sign-in code older than that is no use) plus the conversations with a meeting to come or a bill, found by their ids. Notes are kept per conversation and dropped for one conversation when its text arrives (`forgetNote`). Sign-in codes build their pattern once and skip mail without three digits in a row.
- Grouping newsletters by list has to go through every conversation, so above 5,000 conversations it's done away from the main thread, a moment after the mail last changed, and the lists from before stay until then (`mailingListsNow`).
- A refresh that brings back the same mail changes nothing (`LoadedAccount.isUnchanged`, compared away from the main thread): no redraw, nothing saved.

**Saved mail is looked up, never read through.** See "Saved mail and search" below.

What still grows, and with what:

- The work of a refresh grows with what's in memory for that mailbox (the page, plus what was scrolled to), not with the mailbox.
- Typing in the list's search field filters the loaded mail, and looks at each loaded conversation once per keystroke.
- An IMAP connection keeps the largest window it was asked for until the app quits, so a mailbox that was scrolled far down refreshes that much until then. With QRESYNC or CONDSTORE that's one short answer; without, the flags of every message in the window.
- Scrolling far is one request per 200 conversations. Nobody scrolls to a million; that's what search is for.

Tests: `Tests/MailUITests/LargeMailboxTests.swift`, `MailCacheScaleTests` in `Tests/MailCoreTests/MailCacheTests.swift`.

## Measuring at size

`-benchmark <file.txt>` (Mac app, with `-benchmark-accounts 10 -benchmark-threads 200`) fills the app with a made-up load (formatted shop mail of 40 to 120 KB, conversations with quoted history, labels, Sent), steps through it the way a person does, and writes how long each step took from the action to the mail being on screen, and how long the main thread kept everything else waiting meanwhile: next mail in All inboxes and in one mailbox, switching mailbox, Home and back, holding the key (a new mail every 70 ms), typing in a reply, scrolling to the end of the list, and next mail again that far down. It also writes how much memory the app holds. `-benchmark-only pages`, `tabs` (All, Important and Other) or `typing` repeats just that part, for profiling with `sample`. Nothing is fetched.

It runs in two ways:

- **All in memory** (the default): every conversation is held in memory, as if each had been scrolled to. The app never does this; it's the hardest case for the lists and counts, and shows whether a step's work grows with the amount of mail.
- **Saved** (`-benchmark-saved <folder>`): the mailboxes are held the way the app really holds them. Every conversation is in a saved-mail database in that folder (written on the first run of a size, used again after) and on a made-up server (`BenchmarkProvider`); the app fills its window from saved mail as at launch, refreshes, and fetches older mail when the list is scrolled. This run also writes how long the window took to fill, a refresh with nothing new, and searches of saved mail.

Build it like a snapshot build, but in Release:

```bash
cd Apps && xcodebuild -scheme "Margin (Release)" -derivedDataPath ../.build/xcode-bench CODE_SIGN_ENTITLEMENTS= MARGIN_BUNDLE_ID=app.relevate.margin.snapshot CODE_SIGN_IDENTITY="-" build
../.build/xcode-bench/Build/Products/Release/Margin.app/Contents/MacOS/Margin -benchmark /tmp/bench.txt -benchmark-accounts 10 -benchmark-threads 20000
../.build/xcode-bench/Build/Products/Release/Margin.app/Contents/MacOS/Margin -benchmark /tmp/bench.txt -benchmark-accounts 10 -benchmark-threads 100000 -benchmark-saved /tmp/bench-store
```

### What the first runs found

With ten mailboxes of 200, which is what the app held then:

- **Lists were rebuilt on every ask.** The merged inbox (every mailbox, sorted), what's on screen, the open conversation, the unread counts, the newsletter list and Home's count were worked out from scratch each of the many times a redraw asked. They're kept now until something they were worked out from changes (`Derived`, which uses Observation's own tracking to know what that is, and tells the views that showed the old value).
- **Every formatted mail started a web process.** A mail view that's done is now wiped (page, cookies, caches) and used for the next mail (`MailWebViewPool`).
- **Per-mail text work.** Keys for a mail's HTML hash its bytes (`TextKey`) instead of Swift's normalising string hash; finding quoted history searches lowered bytes once instead of seven case-insensitive passes, builds its patterns once, and skips them when the mail holds no "From:" label at all.
- **Newsletters.** Grouping mail by list is kept apart from counting what was opened, and the opened state is saved after a pause, off the main thread.

That took next mail from 109 ms to 57 ms (90th percentile 176 to 91) and switching pages from 116 ms to 72 ms (worst 408 to 155). Holding the key still keeps the main thread fully busy (about 70 ms of work per mail, mostly SwiftUI and AppKit building the views).

### At 20,000 a mailbox and beyond

With 20,000 conversations in each of ten mailboxes the kept lists weren't enough: marking one mail read dropped every one of them, and each was worked out again by walking 200,000 conversations ("needs you" alone ran its sign-in code search over all of them). Next mail took 190 ms typically and over a second one time in ten; Home took up to 3 seconds. "Mailboxes of any size" above is what was done about it. Measured on the same Mac (ms from the action to the mail on screen, median, with the 90th percentile in brackets):

| Conversations | | Before | Now, all in memory | Now, saved (as the app holds it) |
|---|---|---|---|---|
| 10 × 200 | Next mail, All inboxes | 57 (89) | 57 (89) | 52 (87) |
| | Next mail, one mailbox | 52 (97) | 76 (101) | 76 (127) |
| | Switching mailbox | 67 (91) | 68 (83) | 66 (89) |
| | Typing a letter in a reply | 26 (31) | 21 (26) | 20 (23) |
| | Memory at the end of the run | not measured | 138 MB | 137 MB |
| 10 × 20,000 | Next mail, All inboxes | 190 (1,222), worst 1,471 | 61 (97) | 59 (90) |
| | Next mail, one mailbox | 51 (926), worst 991 | 74 (97) | 81 (123) |
| | Switching mailbox | 121 (134) | 66 (85) | 65 (83) |
| | Typing a letter in a reply | 39 (43) | 19 (21) | 20 (22) |
| | Memory at the end of the run | 991 MB | 509 MB | 129 MB |
| 10 × 100,000 | Next mail, All inboxes | not run | 64 (116) | 58 (84) |
| | Next mail, one mailbox | | 72 (98) | 75 (119) |
| | Switching mailbox | | 68 (82) | 66 (84) |
| | Typing a letter in a reply | | 20 (24) | 20 (23) |
| | Memory at the end of the run | | 1,815 MB | 170 MB |
| 1 × 1,000,000 | Next mail, All inboxes | not run | 76 (99) | 83 (137) |
| | Next mail, one mailbox | | 45 (55) | 47 (62) |
| | Typing a letter in a reply | | 21 (23) | 20 (23) |
| | Memory at the end of the run | | 1,738 MB | 153 MB |

Notes on reading it:

- "Before" was timed with the harness as it was then, whose count of the main thread's busy time stopped working once the main thread never rested; the times to the mail being on screen were taken the same way then and now, so those are what's compared. The 991 MB before includes the text of every made-up mail, which the harness then kept for all of them; it keeps the newest 2,000 per mailbox now.
- One mailbox of a million shows different mail in "All inboxes" than ten mailboxes do (conversations with quoted history between the formatted mail), which is why its 76 isn't the 57 to 64 above it.
- Home and back: with 200 a mailbox the main thread was busy for about 0.1 s a step then and now. At 20,000 a mailbox it took up to 2.8 s to show (3 s in another run); now the main thread is busy 0.1 s (median) and 0.22 to 0.26 s (worst).
- Holding the key (30 mails, one every 70 ms) settles in 2.3 s at every size, with no block longer than about 60 ms. At 20,000 a mailbox it took 4.1 s before, with one block of 3.8 s.

What the saved runs add (ten mailboxes, or one of a million):

| Saved conversations | 2,000 | 200,000 | 1,000,000 | 1,000,000 (one mailbox) |
|---|---|---|---|---|
| Messages, size on disk | 3,223, 10 MB | 320,023, 367 MB | 1,600,023, 1.8 GB | 1,600,023, 1.8 GB |
| Filling the window from saved mail (what launch waits for) | 51 ms | 46 ms | 43 ms | 35 ms |
| A refresh with nothing new | 51 ms, 0 rows written | 30 ms, 0 | 40 ms, 0 | 39 ms, 0 |
| Scrolling to the end: older mail from saved mail and the server, slowest | 98 ms | 215 ms | 343 ms | 126 ms |
| Search of saved mail, slowest of four | 3 ms | 150 ms | 298 ms | 249 ms |
| People for the To field, slowest of four | 6 ms | 35 ms | 245 ms | 45 ms |

Filling the window used to read one mailbox after another, texts included: 458 ms for ten mailboxes, whatever their size. Writing the made-up mail to the database the first time runs at about 28,000 conversations a second (36 s for a million); the app itself writes a page of 200 at a time. Making the made-up mail in memory takes 0.05 s for 2,000 conversations, 0.9 s for 200,000 and 3.3 s for a million (it took 3.9 s for 200,000, most of it saving the label file once per label).

Where it stops, and why:

- **All in memory stops at memory.** Steps stay the same up to a million conversations, but each conversation costs about 1.7 KB, so a million is 1.7 GB. That's the reason the app keeps a window in memory and the rest in saved mail, where a million costs nothing until it's scrolled to. With a million in memory, the first time Home is opened after mail arrives or leaves blocks the main thread for 0.3 to 0.5 s (one look through everything for labels, bills and meetings); as the app holds it, 0.1 to 0.25 s.
- **Saved mail showed no limit up to 1.6 million messages.** Launch, a refresh and a page of older mail take the same time at every size. What grows is the file (about 1.1 KB a message with its search index) and searches for words that are in a great many messages, which are held to a few tenths of a second by ranking the latest 4,000 matches.
- **Scrolling far costs what was scrolled.** Each 200 conversations scrolled to are 200 more in memory and in every refresh, until the list is left. When ten mailboxes fetch a page together the main thread is busy for about 0.1 s once, as 2,000 conversations come in.
- **Not measured here:** a real server holding a million messages (opening the folder and fetching a page take what that server takes; the made-up one answers at once), and an iPhone.

## Writing without redrawing the window

The message being written lives in the model (`compose`, `reply`), and every keystroke changes it. Views around the editor used to read it, so each keystroke worked out the whole open conversation again (a reply) or the list and the reading pane (a new message), which made typing stutter. They now read `isWritingNew` and `isWritingReply`, which only change when writing starts or stops; the text is read by the editor's own small host view and nothing else (`ReplyEditorHost`, `ComposeHost`, `TouchComposerHost`). Tests: `Tests/MailUITests/TypingTests.swift`.

## Accounts and secrets

`AccountStore` saves the account list (names, hosts, ports, colour) as JSON in Application Support. Passwords, app passwords, API tokens and OAuth tokens are stored only in the Keychain, under the account's id, and are readable on this device only. `KeychainCredentials` refreshes OAuth tokens when they're about to expire.

### Signing in again

A mailbox whose sign-in stopped working (an expired or withdrawn Google or Microsoft sign-in, a changed password) doesn't have to be removed and added back. **Sign in again** replaces only the secret in the Keychain; the saved mail, labels, rules, settings and the mailbox's place in the list stay as they are (`MailModel+SignIn.swift`, `SignInAgain.swift`).

- Where: Settings → Mailboxes → the mailbox's ⋯ menu → Sign In Again… and a right-click on the mailbox in the account column (always there); and, when the provider refused the sign-in, a "Sign in again" button under the error in the sidebar, next to the status line at the foot of the list (Mac, iPhone and iPad), and in the empty list's message.
- Google and Microsoft open the provider's own sign-in page with the address filled in. Whether it's the right account is proved by the mail server taking the new sign-in for this mailbox, not by comparing names (the name a provider signs people in under is often an alias or a work name on another domain). When the server refuses it, the old sign-in is put back and the message says who signed in. Errors show in the window the button was pressed in; Settings also confirms when it worked. Other mailboxes ask for the password (or token); a password that doesn't work is thrown away and the old one put back.
- Afterwards the connection is made afresh, pauses on token refreshes are lifted, the mailbox reloads and waits for new mail again. For Microsoft, extras that were turned on (contacts, calendar…) and no longer answer are renewed from the same sign-in.
- "Refused" means the server said no to the sign-in (`MailError.authenticationFailed`, `.missingCredentials`), kept per account in `MailModel.signInRefused`; a network failure never offers it.

Tests: `Tests/MailUITests/SignInAgainTests.swift`.

## State: MailModel

`MailModel` (in MailUI, main actor) holds every account's folders and inbox at once:

- `inboxes[accountID]` and `mailboxes[accountID]` are loaded in parallel on refresh. Each account's result is taken in the moment it arrives (`MailModel.apply`), so an account that fails or is slow never holds the others back; new mail noticed for one account while a full refresh is still running is fetched for that account alone (`reload(only:)`).
- Thread ids only need to be unique within one account, so the model prefixes them with the account id (`MailModel.tag`) and sets `thread.accountID`.
- `Place` says what the list shows: an inbox (one account or all of them, optionally one split), Starred, one account's folder, or `.combined(role)`: the same kind of folder (Sent, Drafts, Archive, Junk, Trash) fetched from every account in parallel and merged by date. Archive falls back to an account's all-mail folder.
- Actions are applied locally first, so the list responds straight away, and then sent to each thread's own account.
- Done and Trash wait 5 seconds before they reach the server. Undo just cancels the wait. This works the same on every protocol, whereas reversing an IMAP move afterwards would mean guessing the messages' new ids. Anything still waiting is sent when the app quits.

### Workspaces

A workspace shows its own mailboxes; "All inboxes" shows every one. A mailbox that's in no workspace at all (just added, or its workspace was deleted) shows in every workspace: nobody chose to hide it, and a mailbox must never drop out of the account column by itself (`MailModel.workspaceAccounts`). Deleting a workspace never removes a mailbox or its mail. The editor binds each row by id, not by place: a name field still writing to a workspace that was just deleted used to stop the app. The "Sign in again" next to the status line only speaks for mailboxes in view. Tests: `Tests/MailUITests/WorkspaceDeletionTests.swift`.

### The window bar's double-click

The empty part of the window bar stands in for a title bar (`TitleBarArea`). Newer versions of macOS answer a double-click there by themselves; older ones don't. Margin waits a moment after the double-click and acts (zoom or minimize, as System Settings says) only if the window hasn't moved, so the window is never zoomed and sent straight back.

## Triage on the device

- `Threader` groups messages by `In-Reply-To` and `References` first. A reply whose parent wasn't fetched joins by its normalised subject.
- `InboxSplit` sorts mail into People, Updates and Newsletters from standard headers: `List-Id`, `List-Unsubscribe`, `Precedence`, `Auto-Submitted`, and no-reply style senders.
- `SearchQuery` searches the loaded mail with `from:`, `to:`, `subject:`, `is:unread`, `is:starred`, `has:attachment`, `in:people` and quoted phrases.

## HTML mail

HTML mail is shown in a locked-down WebKit view (`HTMLMessageView`), the one place the app draws web content, because HTML mail *is* web content. Several locks are layered:

- `HTMLSanitizer` (MailCore) removes scripts, frames, embeds, forms, event handlers, `javascript:` links, `<base>` and meta refresh. It also counts remote resources and likely tracking pixels.
- WebKit runs with page scripts off, a non-persistent data store, and a content rule that blocks every load except `data:`, `about:` and `blob:`. If that rule can't be installed, the HTML isn't shown at all.
- A click inside a mail can only open a web link in the browser or a mail link in a new message; `data:`, `file:` and other apps' schemes do nothing, and nothing replaces the mail without a click (`HTMLWebCoordinator.decision`).
- The cleaner also catches handlers after a slash or quote (`<svg/onload=…>`), `srcdoc`, and script or page URLs however they're disguised (character references, tabs, `&colon;`, `data:text/html`, `data:image/svg+xml`), in every attribute that points somewhere (`HTMLSanitizer.isDangerousURL`).
- Attachments: names lose folder separators, direction-flipping and invisible characters and leading dots (`AttachmentSafety.safeFilename`); files written are marked as downloaded (quarantine), so Gatekeeper checks them; apps, installers, scripts and shortcuts are never opened from mail, only shown in Finder (`AttachmentSafety.isRisky`).
- **No sandbox.** Margin is a direct download so it can run Claude Code and Codex for the assistant, which the App Sandbox forbids. The lines above are its defences; `LSFileQuarantineEnabled` keeps files it writes quarantined; Hardened Runtime stays on. Data the sandboxed versions kept in `~/Library/Containers/<bundle id>` is copied once on the first launch outside (`SandboxMigration`), files that are already there kept, the container left as a copy. The MCP setup now writes an AI app's settings file directly instead of asking to pick it. Tests: `SafetyTests` (bypasses, attachment names and kinds, 400 rounds of corrupted and random mail through every parser, deep nesting), `AppSafetyTests` (WebKit setup, link rule, quarantine, sign-in codes), `SandboxMigrationTests`.
- Remote pictures stay off until you choose "Load pictures" (this message) or "Always for this sender" (kept on this device). Loading them tells the sender you opened the mail, which is why it's a choice.
- Links open in the browser. `mailto:` links open Margin's composer, from the account the mail arrived in.
- In dark mode, mail that declares dark support (`color-scheme`, `prefers-color-scheme`) renders dark. Anything else sits on a white sheet, so a layout designed for light backgrounds stays readable.

- Settings → Reading → "Show mail as" sets plain text instead for everyone who'd rather have no web view. Plain text uses the mail's own text part, or text taken from the HTML when there is none. Each message can still switch with "Show as plain text" / "Show original layout".

- Mail built to a fixed width (a 600-point newsletter in a narrow pane, or on a phone) is scaled down whole to the width it has, like a page in a browser, never below 40 percent (`HTMLWebCoordinator.fitScript`, run in the app's own script world each time the view is measured). Mail that fits is left alone, and widening the pane takes the scaling off again. Tests: `Tests/MailUITests/HTMLFitTests.swift`.

`cid:` inline images aren't fetched yet; see the roadmap.

### Selecting text past the edge

A mail's text is a web view (or a text) at its full height inside the reader's scroll view, so
nothing scrolls by itself while a selection is dragged. `DragSelectScroll` (Mac) watches drags
that begin in the reader: with the pointer near or past the top or bottom it scrolls the reader,
faster the further out, and sends the view under the pointer another drag event so the selection
reaches the text that came into view. `.scrollsWhileSelecting()` inside a scroll view's content
turns it on for that scroll view. Touch screens scroll selections themselves.

## A window of any size

The Mac window goes down to 480 by 440 points, and the columns give way in order (`MailModel.fit(windowWidth:)`):

1. Below 956 points the mailbox column leaves the row; the sidebar button opens it as a drawer over the mail instead, and New message moves into the list's header.
2. Below 680 points of room for mail, the list and the open conversation take turns, with a back arrow, the same way the Wide layout reads mail.
3. In between, the list narrows so the conversation keeps at least 360 points.

Nothing in the reading pane may ask for more width than it gets: its top bar picks the widest row that fits (button names, icons, icons packed tight, and as a last resort a row that scrolls sideways; which mailbox and group a conversation is in is said under its subject, not in the bar); the reply box's tools and the suggested replies scroll sideways; the side margins shrink. Hiding the sidebar yourself is kept apart from the window doing it (`isSidebarHidden` versus `sidebarNeedsDrawer`), so making the window wide again brings back what you had. Tests: `Tests/MailUITests/WindowFitTests.swift`; `-snapshot-reader` and `-snapshot-drawer` show the narrow states in snapshots.

## Older mail on this device

Besides what's scrolled to, Margin downloads the headers of older mail in the background (sender,
recipients, subject, date, flags, list headers and the short preview; never files), so
all of it can be searched (Return) and scrolled without asking a server, also offline
(`MailModel+Download.swift`).

- **How much:** Settings → Mailboxes → **Keep on this device**: Off, 3 months, 1 year, Everything.
  The Mac keeps everything, iPhone and iPad the last year. It's set per device (`keepMail`, not
  in `backedUpSettings`). The same section shows how many messages are saved and the file's size,
  and **Clear Downloaded Mail** takes out what has no saved text below each folder's newest 500
  (it downloads again unless set to Off).
- **The text of recent mail:** Settings → Mailboxes → **Open recent mail instantly** (`keepText`,
  per device: Off, 2 weeks, 3 months, 1 year; the Mac saves three months, iPhone and iPad two
  weeks). Before each header page, `downloadTexts` asks for the text of eight saved messages that
  have none, newest first, per mailbox, down to the stretch's start, so a first open comes from
  disk instead of a server. `MailProvider.readableBodies(of:)` brings them: IMAP fetches the first
  200,000 bytes of each in one request per folder on the main connection (never the one kept for
  the mail on screen). Small mail comes whole; bigger mail as its text without the files, marked
  `isPartial`, and opening it shows the text at once and fetches the files then. A mailbox is
  walked once from the newest down, so a message the server won't give isn't asked for again and
  again, and the walk starts over every quarter of an hour for mail that came in since. The same
  rules for Wi-Fi, battery and Low Power Mode apply.
- **What, in which order:** per mailbox its inbox, then Sent, then Archive (or all mail), one
  folder at a time, one page of 200 messages every two seconds, in a background-priority task.
  Nothing goes into memory (`shelves`): pages go straight to `MailCache.addThreads`.
- **The paging call:** `MailProvider.olderMessages(in:after:limit:)`. IMAP finds the lowest UID
  fetched so far by its sequence number (`UID FETCH u (UID)`, or the nearest one below when it was
  deleted) and fetches the 200 before it on the main connection, inside `exclusive`: a refresh
  waits for at most one page, the mail on screen has its own connection, and no connection is
  added. Nothing is added to `IMAPFolderSync`, so the window a refresh keeps up to date doesn't
  grow. JMAP asks `Email/query` with a `position`. The made-up and sample servers page the same way.
- **Resumable:** where each folder got to is saved in the `downloads` table (position, IMAP
  UIDVALIDITY, the stretch it was finished for), so a quit or a crash carries on from there. A new
  UIDVALIDITY starts the folder again from the newest. Choosing a longer stretch carries on where
  the shorter one stopped.
- **When not:** on iPhone and iPad it stops when the app goes to the background, and only runs on
  Wi-Fi or a cable outside Low Data Mode (`NWPath.isExpensive`, `isConstrained`), outside Low
  Power Mode, and while charging or above 20 percent. A mailbox that can't be reached waits; the
  others go on.

**Keeping it honest.** Once a mailbox's folders are downloaded, saved copies are compared with
the server (`MailProvider.checkSaved`), and messages that are gone are taken out (search index
included), changed flags written, and JMAP moves followed:

- IMAP with CONDSTORE or QRESYNC: every hour; only flags changed since the last mod-sequence are
  fetched, plus one `UID SEARCH` over the saved range to find what's gone.
- IMAP without: once a day, with every saved message's flags.
- JMAP: every hour with `Email/changes` since the last state; when the server can't work out the
  changes, every saved email's folders and keywords once.

What can be stale, and for how long: mail beyond the newest page that was read, starred, moved or
deleted on another device shows the old state until the next check (up to an hour, or up to a
day on IMAP servers without CONDSTORE), or until it's scrolled to (a list's own refresh corrects
it at once). On IMAP, a message moved elsewhere is a deletion here and a new message in its new
folder, found when that folder is downloaded. JMAP paging by position can skip a few messages
deleted while the pages are walked; they're picked up by search on the server, not here.

**Measured** (`OlderMailDownloadTests.measuresFillingTwentyThousand`, made-up server, no pause
between pages): 19,520 messages saved in 0.7 s, about 1.1 MB on disk per 1,000 messages including
the search index, and the main thread never waited more than 2.7 ms. With the pause between pages
filling 20,000 takes about three and a half minutes plus however long the server takes to answer
100 pages. Texts are not downloaded yet; that's the next step if "Everything" is to mean
offline reading too.

Tests: `Tests/MailCoreTests/OlderMailTests.swift` (IMAP and JMAP paging and checks against the fake
servers, saved-mail checks and clearing), `Tests/MailUITests/OlderMailDownloadTests.swift`
(resume, limits, stale correction, search, clearing, scrolling with the server unreachable).

## Saved mail and search

`MailCache` (MailCore/Store) is a SQLite database with an FTS5 full-text index. It holds folders, the conversations of each folder as far as they were fetched, the bodies you've opened, and attachments up to 2 MB. At launch the window fills from it before any server answers. When a server can't be reached, the saved mail stays and the sidebar says so. Pressing Return in the search field searches saved mail at once, then asks every server (IMAP `UID SEARCH TEXT`, JMAP `Email/query` with a text filter) for older mail, and merges the results by Message-ID.

It costs the same with a hundred messages saved or a million:

- Every message has a row number that is also its row in the full-text index, so finding, replacing and joining search rows goes through an index. (Search rows used to be found by account and id, which the index doesn't cover: every save read the whole index.)
- A refresh writes only what changed. Each row carries a `mark` worked out from what a list shows of a message (flags, preview, folder); a message whose mark is the same is skipped, so a refresh that brings nothing new writes nothing. A message's place in the search index is written when it's first saved and when its text is.
- A snapshot of a folder's newest conversations stands in for that stretch of the folder only: saved messages older than its oldest stay (they were saved when the list was scrolled that far), unless fewer came back than were asked for, which means it's the whole folder (`saveThreads(_:account:mailbox:limit:)`).
- Lists read a page through the folder index (`threads(account:mailbox:limit:before:)`), without the saved texts, and are unpacked outside the store, so every mailbox's inbox is unpacked side by side at launch. A text is read when its mail is opened.
- Who you've written to is noted as each message is saved (the `written` table) instead of being read out of every message at every refresh.
- A word that's in tens of thousands of messages is ranked among the latest 4,000 saved that match, not all of them.

A file from before row numbers is brought up to date the first time it's opened: messages are copied into the new table and the search index is filled again from the old one, in one transaction. A build from before can't search a file once it's been brought up to date.

## Everyday tools kept on the device

Snoozes (`snoozes.json`) and the outbox (`outbox.json`) are JSON files in Application Support. The app does the work, so no server is needed:

- **The clock.** A clock in `MailModel+Timing.swift` ticks every 20 seconds. It wakes due snoozes and sends due scheduled messages, and checks for new mail about every 3 minutes, posting notifications for new mail from people. Scheduled mail only goes out while Margin is running.
- **Undo send.** Sending holds the message in memory for the undo delay before it reaches SMTP or JMAP.
- **Waiting for reply.** Sent mail where you wrote last counts as waiting when no inbox message answers it, by `In-Reply-To`/`References`, or by the same subject from a recipient. A recipient who has since sent a meeting invitation, or a new email on the same subject, in any saved folder (Outlook moves answered invitations to Deleted Items), counts as having answered.
- **Unsubscribe.** Uses RFC 8058 one-click (a cookie-less POST) when the sender supports it, otherwise the list's mail address, otherwise its web page.

## Commands and keyboard

`MailCommand.all(for:)` is the single list of commands. The command palette (⌘K) shows it, the shortcuts sheet (?) documents it, and the single-key handler runs it. A new command only needs adding there. Single keys only act while the conversation list has focus, so they never fire while you're typing.

## Design

The look is called paper and ink: one neutral scale per appearance, and the system font at regular and medium weights only. Colour is used only where it means something: each account's colour, the three parts of the inbox, a steady colour per sender, and a blue unread mark. All tokens live in `Sources/MailUI/Design/Theme.swift`; views never hard-code colours.

### Roomy and Compact

The interface comes in two sizes, chosen in Settings → Appearance → Size and kept as `density`
(it travels with a backup). **Roomy** is the default: on the Mac, text is a point bigger (two from
16 up), gaps and row heights grow by a quarter, and the rail, the top band and the mailbox and
list columns are wider. **Compact** is the tighter look for people who want more on screen. On
iPhone and iPad, Roomy is the size touch screens always had and Compact takes a point off text.

Views never branch on the setting. They ask `Look` (in `Design/Theme.swift`): `Look.size(_:)` for
a type size, `Look.gap(_:)` for a gap, padding or fixed height, and `Look.pick(_:roomy:)` for the
few hand-picked sizes. `TypeScale` and `Space` go through the same calls, so a new view that uses
the tokens follows the setting for free; a literal `.font(.system(size: 13))` or
`.frame(height: 34)` does not, so wrap it. The density is part of `Look.key`, so changing it
redraws the window once. Mail's own HTML is left at the sender's size; plain-text mail follows.

`-snapshot-density-compact` captures the Compact look in snapshot mode.

## Checking the UI without screen recording

`-snapshot <file.png>` launches the app with the sample mailboxes, renders the window to a PNG and quits. Add `-appearance light|dark`, `-snapshot-palette`, `-snapshot-compose`, `-snapshot-mailbox 0`, `-snapshot-combined sent`, `-snapshot-select "Issue 212"` or `-snapshot-size 1520x940` (the window at that size in points, drawn two pixels a point). `-snapshot-cc "maya@example.com, no"` (with `-snapshot-compose`) opens Cc and Bcc with that in Cc. Put flags that take no value last: AppKit reads `-flag value` pairs, so a bare flag swallows the next one and a stray word after that is taken for a file to open, and no window comes up. Add `-snapshot-glass` to save the system's own picture of the real window instead, with Liquid Glass and scrolling parts in it; the window shows on a Retina screen for a moment. The website's pictures are made that way. Web content is drawn in another process, so snapshot mode paints each web view's own snapshot over its frame. A sandboxed build can only write inside its container, so build without the sandbox entitlement for snapshots:

```bash
cd Apps && xcodebuild -scheme Margin -derivedDataPath ../.build/xcode-snapshot CODE_SIGN_ENTITLEMENTS= MARGIN_BUNDLE_ID=app.relevate.margin.snapshot build
../.build/xcode-snapshot/Build/Products/Debug/Margin.app/Contents/MacOS/Margin -snapshot /tmp/margin.png -appearance dark
```

## Quoted history

A reply usually carries the earlier mail underneath ("On Tuesday, Jodi wrote: …"). In a
conversation that mail is already on the page, so the reader folds it away behind a "···"
button (`QuoteToggle`); pressing it shows the message whole.

- `QuotedHistory` (MailUI) finds where the quote starts: a blockquote, Gmail's quote container,
  Outlook's containers (`divRplyFwdMsg`, the new Outlook's
  `mail-editor-reference-message-container`), a bold "From: … Sent: …" block with its rule or
  bordered box, plain "From: Name <address> / To: / Date:" rows with the rule above them (the
  From row must hold an address, so a booking's "From: Amsterdam" isn't one), or in text a "> " line, "On … wrote:" (several languages) or a "From: / Sent:"
  block. An "On … wrote:" line sitting just before the quote goes with it.
- Folded: any message that has something of its own above the quote, also when it's the only
  one on the page (a sent reply seen in Sent). Not folded: forwards (by subject prefix: the
  quoted part is the point; translating a forward takes the quoted part along for the same
  reason), and messages that are nothing but a quote.
- HTML is cut at that point before it's shown; the browser closes the open tags. Translating a
  message already left the quoted part alone, and uses the same detection.

Tests: `Tests/MailUITests/QuotedHistoryTests.swift`.


## Window extras

- **Top bar:** whether mail is up to date (a check mark, turning while mail is checked, a warning
  when offline or a sign-in was refused; click to check now), and an Outbox chip while messages wait
  to be sent (`SyncStatusButton`, `OutboxButton` in `WindowBar.swift`). Compose stays in the sidebar,
  or in the list's header when the sidebar is hidden.
- **Dock:** the unread count on Margin's icon, following the same count as the rail, so it drops as
  soon as mail is read; off in Settings → Notifications (`DockBadge.swift`).
- **Rows:** Done, Mark read and Move to Trash at the end of a row under the pointer; off in
  Settings → Swipes (`RowHoverActions.swift`).
- **Inbox tabs:** All, Important (mail from people) and Other (updates and newsletters together)
  are glass tabs under the inbox title, ⌘1–⌘3. The split itself still knows updates from
  newsletters (a conversation's header says which); the shelf keeps "Other" as one bit of its
  facts, so the tab filters as fast as the others (`InboxShelf.Facts.otherBit`).
- **Account column:** scrolls when there are more mailboxes than fit, with Add a mailbox in view.
  It can be hidden (Settings → Appearance → Account column): All inboxes, Home, the Calendar and the
  mailboxes then sit at the top of the sidebar, which also stays on the Calendar (`RailOptional.swift`).
- **Home** leaves the reading pane on Ask until a conversation is clicked (with an assistant).
- **Help** (the ? above Settings in the account column, Help → Margin Help…, or ⌘K "Help and
  feedback") slides in as a panel at the right, moving the mail over. It has a search; how each
  mailbox is doing (up to date, offline, or signed out with Sign In) with Check Now; short how-tos
  (Home, searching, Ask when there's an assistant, rules, snooze and Undo, AI apps, backups), each
  with a button that goes there; the keys used most; and Send Feedback / Report a Problem, which open
  a message to the Margin team (hello@relevate.app for now) with the app version filled in
  (`HelpPanel.swift`).
- **⌘K** ranks what fits best: the start of a title, the start of a word, the text anywhere, then
  initials ("md" for Mark done). Letters scattered through a title no longer count
  (`CommandPalette.score`).
- **Settings** has Back and Forward in its toolbar (⌘[ and ⌘]), as in a browser (`SettingsHistory`).
- **Meeting reminders** have their own sound (Settings → Notifications → Reminder sound), so a
  meeting doesn't sound like new mail.
- **Translation:** Translate in a conversation's header translates every message. Mail in a language
  the system's translation doesn't offer is translated by the assistant instead, as plain text, when
  there is one (`MailIntelligence.translate`).
