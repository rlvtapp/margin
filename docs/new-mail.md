# New mail without a server

Margin has no server of its own, so new-mail alerts come straight from each mail server.

- **While Margin runs (Mac, and iPhone/iPad in the foreground):** a second connection per mailbox
  sits in IMAP IDLE (RFC 2177) on the inbox. The server says `* n EXISTS` the moment mail arrives
  and Margin reloads at once. The connection is renewed every 25 minutes (servers drop IDLE after
  30). Servers without IDLE, and JMAP accounts for now, fall back to the three-minute timer.
  Code: `IMAPClient.idle`, `IMAPProvider.waitForInboxChange`, `MailModel.startWatching`.
- **iPhone and iPad in the background:** Background App Refresh (`app.relevate.margin.refresh`).
  iOS decides when to wake Margin, often every 15 minutes to a few hours. Margin fetches, alerts
  about mail it hasn't alerted about before (remembered in `seen-unread.json`), and asks to be
  woken again. Code: `MarginTouchApp`, `MailModel.checkForNewMail`.
- **Instant notifications on iPhone and iPad** for Gmail, Microsoft and JMAP accounts: the
  provider reports new mail to Margin's relay, which only forwards a contentless ping through
  Apple's push service; Margin then fetches the mail itself. No setup and no setting; plain IMAP
  accounts keep Background App Refresh. See [push.md](push.md).

## What a refresh fetches

Each account's provider remembers, in memory, what every folder held at the last refresh, so
the next one asks only for what changed. Results to the app are the same as a full fetch.

- **IMAP with QRESYNC** (RFC 7162): Margin sends `ENABLE QRESYNC` after signing in, then
  `SELECT folder (QRESYNC (uidvalidity modseq known-uids))`. The server answers in the same
  reply with `VANISHED` for removed messages and `FETCH (FLAGS)` for changed ones. When
  HIGHESTMODSEQ moved, one `UID SEARCH` finds new UIDs. Only those are fetched whole.
- **IMAP with CONDSTORE only** (Gmail): `SELECT folder (CONDSTORE)`. Same HIGHESTMODSEQ and
  message count means nothing happened and nothing more is asked. Otherwise one
  `UID FETCH lowest:* (UID FLAGS) (CHANGEDSINCE modseq)` returns the changed flags and the new
  messages together (every arrival raises HIGHESTMODSEQ). When the new count is the old one plus
  those arrivals, nothing left; only when it doesn't add up does a `UID SEARCH` find what left.
- **Plain IMAP** (Outlook, Microsoft 365): when the count or UIDNEXT moved, one
  `UID FETCH lowest:* (UID FLAGS)` lists what's still there, what's new and every flag; when
  they didn't, the same for the known messages only. Only new UIDs are fetched whole.
- When messages leave, the gap is filled from just below by sequence number. A new
  UIDVALIDITY, or counts that don't add up, fall back to fetching the newest messages whole.
- **JMAP**: `Mailbox/changes` and `Email/changes` with the state strings from the last
  refresh, with the created and updated items fetched in the same request. A flag change is
  applied in place; new, moved or removed emails make the folder ask `Email/query` for its
  thread ids again, and only emails not already in memory are fetched. When the server can't
  say what changed (`cannotCalculateChanges`), Margin fetches everything again.

For IMAP the remembered state is also kept between launches (`IMAPSyncStore`): one file per
mailbox in `IMAP Sync/` in the app's folder, written on the side after a check that changed
something, holding the same headers and previews as saved mail (never a body, password or
token). The first check after launch picks up from it, so it asks only for what changed while
Margin was closed. It's brought back with at most the newest 200 messages per folder, belongs to
one server and user name (another one starts afresh), is dropped for a folder whose UIDVALIDITY
changed, and is deleted when the mailbox is removed. JMAP's state strings still live only while
the app runs. Code: `IMAPProvider.refresh`, `IMAPSyncStore`, `IMAPClient.selectMailbox`,
`JMAPSync.swift`. Tests: `SyncStoreTests`.

## How long a check takes

A check is a few commands per mailbox, all mailboxes at once, so its time is the slowest
mailbox's number of round trips. What keeps that number small:

- **The folder list is kept.** `IMAPProvider.mailboxes()` asks the server for the list at most
  every five minutes (`folderListAge`), after a reconnect, and when a folder is made, renamed or
  deleted here. Every check used to send `LIST` first, and a new connection sent it twice.
- **Checks go first.** One connection per mailbox does one folder operation at a time.
  Downloads of message text (reading ahead, invitations, the assistant, an open conversation's
  older messages, saved-mail checks) wait in a second line (`exclusive(.later)`) that only moves
  when no check or action waits. A check waits for the download under way, not for every one
  queued before it. The mail you click is read on its own connection and waits for neither.
- **Reading ahead is one request.** After a check, the newest 20 conversations' texts not yet on
  this device come in one request per mailbox and folder, and only each message's first 200 KB
  (the text; opening it fetches the files, so attachments of those 20 are no longer downloaded
  ahead). It was one whole message per request, files and all.
- **The check ends when the mail is in.** "Checking…" (`isLoading`) ends before the open
  conversation picks up what arrived in it, so the three-minute check isn't skipped meanwhile.
- **Previews are one request per part.** A first download asks for the start of each
  message's text grouped by part number and length only. It used to make one request per
  combination of part, encoding and character set: 24 round trips, one after the other, for
  200 mails on Outlook.com, now 6.
- **The inbox comes first at launch.** The open conversation's server Sent check waits until
  the first check is done; at launch it took the connection first and the inbox waited for a
  whole download of Sent.
- **Signing in** skips `CAPABILITY` when the server already listed them in its sign-in answer
  (`[CAPABILITY …]`).

`Tests/MailCoreTests/CheckSpeedTests.swift` times a check against a scripted server that answers
each command after 100 ms (iCloud answers in about 140 ms from the Netherlands, Gmail and
Outlook in 10 to 20 ms plus their own work):

| Check | Before | After |
| --- | --- | --- |
| First check after signing in, nothing saved yet | 790 ms, 7 commands | 670 ms, 6 |
| Nothing new (CONDSTORE) | 215 ms, 2 commands | 108 ms, 1 |
| One new mail (CONDSTORE) | 533 ms, 5 commands | 320 ms, 3 |
| Nothing new (plain IMAP) | 3 commands | 2 |
| One new mail (plain IMAP) | 5 commands | 3 |
| While 12 downloads are queued | 1,459 ms | 182 ms |

These are a scripted server's numbers, not a real account's. On real accounts (November
2026, from the Netherlands, four mailboxes), the check at launch went from 26.3 s to 9.1 s with
fewer preview requests, and to 2.0 s once the folder state was kept between launches (it used
to download each inbox's newest 200 messages again; Outlook.com alone took 7.7 s for that). Signing in takes under a second everywhere. Later checks take 50 to 200 ms on
Gmail, iCloud and Microsoft 365 and 0.4 to 0.8 s on Outlook.com.

Each check's time is in the system log:
`/usr/bin/log stream --predicate 'subsystem == "app.relevate.margin" && category == "refresh"'` shows
"Checked mailbox … in … ms" per mailbox and "Checked n mailboxes in … ms". The full path matters: in zsh, `log` is a
shell builtin that does something else. Each mailbox's lines also say where its time went: signing in
(open, token, sign in), the folder list, waiting for the connection, the sync, and for a full
download the list items and the preview requests (`StepTimes` in MailCore, sent to the log by
MailUI; no addresses, tokens or mail).
