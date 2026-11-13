# Roadmap

Roughly in order. Each item keeps the same rule: the device talks to the mail server directly.

## To do

- **More inbox categories.** Primary, Updates, Promotions, Social and Forums, and "Move sender to" so a sender always lands in the same one.
- **A "needs reply" mark** on rows, and grouping the list by sender or domain.
- **Smart folders** (saved searches with rules that also ask the server) and **nested labels** (Work/Clients).
- **Open at login.**
- **Reading:** a slim header that stays while scrolling.
- **Writing:** Send Again. Formatting on iPhone and iPad (the editor there is plain text).

## Next

- **JMAP push** (EventSource). IMAP `IDLE` is done (see [new-mail.md](new-mail.md)).
- **Drafts as you type.** Today a draft is saved when you close the message.

## Then

- **Per-sender permissions for connections** and an approval prompt in Margin before an AI app sends.

## Not in Margin

- **A calendar.** Calendar is its own app, Daybook. Margin only handles what arrives by mail:
  invitations, answers, the next meeting, and sending a meeting (with rooms) from New Meeting. When
  Daybook is installed, the two hand things to each other ([daybook.md](daybook.md)).

## Integrations (optional, off by default)

The app is complete without any service. Integrations are small, optional and use open protocols:

- **Relevate.** Add a Relevate mailbox the same way as any other account (IMAP/SMTP or JMAP), plus an optional panel that shows a sender's company and next step. Nothing changes for people who don't use Relevate.
