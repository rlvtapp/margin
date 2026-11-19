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

### Rules: one list, one editor

Settings → **Rules** lists every rule, each marked with where it runs and for which mailbox, and
one editor below makes and changes them all (Create Rule… uses the same one):

- **When** (all that are filled in must match): **From contains**, **To contains**, **Subject
  contains**, **Has an attachment**.
- **Then** (any number): **Leave in Inbox / Archive / Move to folder… / Move to Trash** (one move per
  rule), **Mark as read**, **Star**, **Forward to**, and, only in Margin, **Label**, **Answer** and
  **Keep quiet (no alert)**. Trash is never permanent deletion.
- **Mailbox:** all mailboxes or one.
- **Runs:** **On the server** or **In Margin**. A rule on the server runs on new mail even when
  every device is off. A new rule for one mailbox goes on its server when that server keeps rules;
  a rule for all mailboxes, or one that labels, answers or keeps quiet, runs in Margin. Switching
  **Runs** on a saved rule moves it: it's saved in the new place first, then taken out of the old
  one, so a rule is never in both and nothing runs twice. Microsoft and Gmail mailboxes show **Set
  Up Server Rules…** until the account allows it.

Rules on the server aren't copied into Margin: the list is read from each server, and **Edit** and
**Remove** change the server's own rules. Rules made elsewhere that Margin can't show completely (a
body condition, several senders, a filter search, a Sieve rule that stops later rules) are listed
with **Remove** only, because saving them would lose those parts.

How each server keeps them:

- **Microsoft 365 / Outlook.com:** Graph inbox rules (`/me/mailFolders/inbox/messageRules`,
  `senderContains`, `recipientContains`, `subjectContains`, `hasAttachments`; `moveToFolder`,
  `markAsRead`, `forwardTo`, `delete`). Archive moves to the folder Graph calls `archive`. Graph
  rules can't flag, so **Star** marks the email important (`markImportance: high`), and the editor
  says so. A change is saved as a new rule in the old one's place, then the old one is removed, so
  nothing cleared is left behind. It asks once for `APIAccess.rules`: `MailboxSettings.ReadWrite`,
  plus `Mail.ReadBasic` to list folders. Shared mailboxes keep their rules in Margin.
- **Gmail:** filters (`users.settings.filters`). Move adds the label and removes `INBOX`; Archive
  removes `INBOX`; Mark as read removes `UNREAD`; Star adds `STARRED`; Trash adds `TRASH`; Forward
  sets `forward`, which Gmail accepts only for a forwarding address already verified in Gmail.
  Gmail can't change a filter, so a change makes the new filter first and then removes the old one.
  It asks once for `gmail.settings.basic` (the same as the automatic reply); labels are listed with
  the mail sign-in.
- **Other IMAP servers:** ManageSieve (RFC 5804) on port 4190 of the IMAP host, with STARTTLS and
  the mailbox's password. Margin edits the script that's running, so rules made in webmail keep
  working: rules it understands are written as `# rule:[name]` above an `if`, the shape common
  webmail uses, and everything else, rules Margin didn't change included, stays word for word.
  With no script running, it starts one called `margin` and turns it on. Folder names are sent in
  UTF-8. Star uses `imap4flags`, forwarding uses `redirect :copy` (or `redirect` plus `keep`),
  Archive and Trash are `fileinto` those folders (never `discard`), and **Has an attachment** uses
  the `mime` extension when offered, otherwise `multipart/mixed`.
- **Servers without ManageSieve, JMAP, and accounts signed in another way:** the editor says that
  rules for this mailbox run only while Margin is open.

Rules in Margin run on new inbox mail on every load while Margin is open, before alerts, each
message once, doing each of their actions:

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

Code: `MailModel+Rules.swift` (rules in Margin), `RuleForm.swift` (the one form, for both places),
`RuleEditor.swift`, `RulesSettings.swift`, `MailModel+ServerRules.swift` (`saveRule`,
`ServerRuleBook`), `MailCore/Settings/ServerRules.swift` (Graph, Gmail), `SieveScript.swift`,
`ManageSieve.swift`. Tests: `OneRuleEditorTests`, `ServerRulesTests`, `EssentialsTests`,
`RuleExtrasTests`. Snapshots: `-snapshot-settings rules` (the sample mailbox keeps two rules on its
"server") and `-snapshot-settings server-rule` (the editor changing one).

### Blocked senders, muted conversations, junk

- **Block** (a conversation's … menu): what's in the inbox from them goes to Trash, and so does new
  mail. Unblock in Settings → Rules.
- **Mute** (a conversation's … menu): it's archived now; replies to it are archived and marked read.
- **Move to Junk** (⌘⇧J, `!`, a conversation's … menu or right-click): reports it as junk. It moves
  to the mailbox's Junk folder, marked with the `$Junk` keyword (and `$NotJunk` removed), which is
  how iCloud, Fastmail and other servers learn; Gmail learns from the move itself. In
  Junk the same places say **Not Junk**: back to the inbox, marked `$NotJunk`. Both wait out the
  Undo window like Trash. A server that doesn't keep keywords still gets the move. Code: the
  `.junk`/`.notJunk` actions in `IMAPProvider`, `JMAPProvider` and `MailModel+Actions.swift`.
  Tests: `JunkTests`.

Blocking and muting run on new inbox mail on every load while Margin is open, before alerts, each
message once (the first run only remembers what's there). Code: `MailModel+Rules.swift`. Tests:
`EssentialsTests`.

AI apps connected to Margin can make the same rules from a plain request ("always mark mail from my
bank as important"), when the connection is allowed to change things: `list_rules`, `preview_rule`,
`create_rule`, `update_rule`, `delete_rule` (see [intelligence.md](intelligence.md#connections-mcp)).
They're rules in Margin with one condition and one action, shown in Settings → Rules like any other,
with a notice when one is added, changed or removed. `list_rules` also lists rules made in Settings
with several parts (in `conditions` and `actions`); those can be deleted over MCP but not updated.
Rules kept on a mail server aren't offered to AI apps.
Code: `MailToolbox+Rules.swift`, `RuleForm.swift`, `RuleEditor.swift`, `RuleWriting.swift`. Tests: `RuleToolsTests`, `RuleUpgradeTests`.
