# Roadmap

Roughly in order. Each item keeps the same rule: the device talks to the mail server directly.

## To do

- **More inbox categories.** Primary, Updates, Promotions, Social and Forums, and "Move sender to" so a sender always lands in the same one.
- **A "needs reply" mark** on rows, and grouping the list by sender or domain.
- **Smart folders** (saved searches that also count unread and refresh on their own; saved searches themselves are done, see [search.md](search.md)) and **nested labels** (Work/Clients).
- **Search:** text outside ASCII on IMAP servers (sent as literals with `CHARSET UTF-8`); `OR` and `-` in typed searches; suggestions for operators while typing.
- **Reading:** a slim header that stays while scrolling.
- **Writing:** Send Again. Formatting on iPhone and iPad (the editor there is plain text).

## Next

- **Microsoft Graph mail, what's left:** Outlook's category colours (`/me/outlook/masterCategories`,
  which needs `MailboxSettings.Read`), a push subscription per shared mailbox, and checking saved
  older mail against the server (`checkSaved`) through its own delta query.
- **JMAP push** (EventSource). IMAP `IDLE` is done (see [new-mail.md](new-mail.md)).
- **Drafts on the server as you type.** What you're writing is already kept on the device every
  moment (`unsent.json`, put in Drafts at the next launch after a crash or quit); the server's
  Drafts copy is only written when you close the message, so another device doesn't see it yet.

## Then

- **Per-sender permissions for connections** and an approval prompt in Margin before an AI app sends.

## Calendar

Margin is mail and calendar in one app (decided 2026-11-19): see [calendar.md](calendar.md).
Daybook, the separate calendar app, is being retired; its calendar views are moving into Margin.

## Integrations (optional, off by default)

The app is complete without any service. Integrations are small, optional and use open protocols:

- **Relevate.** Add a Relevate mailbox the same way as any other account (IMAP/SMTP or JMAP), plus an optional panel that shows a sender's company and next step. Nothing changes for people who don't use Relevate.
