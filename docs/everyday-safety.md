# Never losing mail, away replies, rules

The same on Mac, iPhone and iPad.

## Offline outbox

A message that can't be sent because there's no connection (offline, timed out, connection
dropped) waits in the outbox, marked **Waiting for a connection**, and goes out by itself about every
20 seconds once there is one ("Back online: your message was sent"). Anything else the server refuses
(a wrong password, a rejected address) reopens the composer with the reason, as before. Code:
`MailModel.queueSend`, `tick`, `MailError.isConnectionProblem`.

## Drafts as you type

What's in the composer, the reply bar and the Undo Send moment is kept on the device
(`unsent.json`) a moment after each change. If Margin quits or crashes before it's sent or closed,
the next launch puts it in Drafts and says so. Closing still saves to Drafts right away. Code:
`MailModel+Unsent.swift`.

## Automatic reply (out of office)

Mailboxes → Edit… → **Automatic reply**: on or off, optionally between dates, a message (and a
subject where the provider has one), and whether people outside the organization or contacts get it.
The provider sends it, so it works while every device is off.

- **Microsoft 365 / Outlook.com:** Graph `mailboxSettings.automaticRepliesSetting` (asks once for
  `MailboxSettings.ReadWrite`).
- **Gmail:** the vacation responder (asks once for `gmail.settings.basic`; add it to the Google
  consent screen).
- **JMAP:** `VacationResponse`.
- **Plain IMAP:** no standard way for apps; Margin says to use the provider's website.

Code: `MailCore/Settings/AutoReply.swift`, `MailModel+AutoReply.swift`, `AutoReplySection.swift`.

## Rules, blocked senders, muted conversations

Settings → **Rules**.

- **Rules:** "When From / To / Subject contains … then Archive, Move to Trash, Mark as read, Star,
  Label … or Move to folder …", for every mailbox or one.
- **Block** (a conversation's … menu): what's in the inbox from them goes to Trash, and so does new
  mail. Unblock in Settings → Rules.
- **Mute** (a conversation's … menu): it's archived now; replies to it are archived and marked read.

They run on new inbox mail on every load while Margin is open, before alerts, each message once (the
first run only remembers what's there). Code: `MailModel+Rules.swift`, `RulesSettings.swift`. Tests:
`EssentialsTests`, `AutoReplyTests`.

AI apps connected to Margin can make the same rules from a plain request ("always mark mail from my
bank as important"), when the connection is allowed to change things: `list_rules`, `preview_rule`,
`create_rule`, `update_rule`, `delete_rule` (see [intelligence.md](intelligence.md#connections-mcp)).
They show in Settings → Rules like any other, with a notice when one is added, changed or removed.
Code: `MailToolbox+Rules.swift`. Tests: `RuleToolsTests`.
