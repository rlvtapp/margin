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
- **IMAP with CONDSTORE only**: `SELECT folder (CONDSTORE)`. Same HIGHESTMODSEQ and message
  count means nothing happened and nothing more is asked. Otherwise one `UID SEARCH` finds new
  and removed messages, and `UID FETCH … (FLAGS) (CHANGEDSINCE modseq)` the changed flags.
- **Plain IMAP**: the same `UID SEARCH` when the count or UIDNEXT moved, plus a cheap
  `UID FETCH … (FLAGS)` for the messages already known. Only new UIDs are fetched whole.
- When messages leave, the gap is filled from just below by sequence number. A new
  UIDVALIDITY, or counts that don't add up, fall back to fetching the newest messages whole.
- **JMAP**: `Mailbox/changes` and `Email/changes` with the state strings from the last
  refresh, with the created and updated items fetched in the same request. A flag change is
  applied in place; new, moved or removed emails make the folder ask `Email/query` for its
  thread ids again, and only emails not already in memory are fetched. When the server can't
  say what changed (`cannotCalculateChanges`), Margin fetches everything again.

The remembered state lives only while the app runs; the first refresh after launch is a full
one. Code: `IMAPProvider.refresh`, `IMAPClient.selectMailbox`, `JMAPSync.swift`.
