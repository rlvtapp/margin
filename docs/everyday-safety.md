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
  - **Create Rule…** (right-click a conversation): starts a rule from its sender, anyone at their
    domain, or its subject (without "Re:"/"Fwd:"), in its mailbox.
  - **Describe a rule** (with the assistant on): "always star mail from my bank" fills in the form,
    using your real folders, labels, Home groups, mailboxes and the people you write to
    (`MailIntelligence.writeRule`; on-device it's guided generation, hosted models answer JSON).
    Nothing is saved until you press Add Rule.
  - While a rule is filled in, anything missing or that wouldn't work (no text, no label or folder
    name, a folder that isn't in that mailbox) is marked in orange, and the form shows how many inbox
    conversations it would catch now, with the first three.
  - More actions: **Forward to…** an address (with the email's formatting, never back to its
    sender), **Answer with…** a text (each sender at most once every 4 days per rule, never mailing
    lists, no-reply or mailer-daemon addresses, never your own mail), and **Keep quiet** (it arrives
    without an alert or sound). At most 20 automatic sends per check. Over MCP, rules that forward or
    answer also need "Allow sending".
  - **Edit** changes a saved rule in the same form (describing it again in words changes that rule).
    **Start From** offers starter rules. Moving one sender's mail into the same folder three times
    offers a ready rule at the top of the form (`RuleSuggestions.swift`).
  - When rules move new mail (archive, Trash, a folder), one notice says how many, with Undo for
    the usual few seconds; nothing reaches the server until then. Settings → Rules → **Recent
    activity** lists what rules did (last 100), marking what was undone.
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
Code: `MailToolbox+Rules.swift`, `RuleForm.swift`, `RuleEditor.swift`, `RuleWriting.swift`. Tests: `RuleToolsTests`, `RuleUpgradeTests`.
