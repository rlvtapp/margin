# Writing mail

New messages open in a sheet on the Mac and full screen on iPhone and iPad. Closing one keeps
anything written in Drafts.

## Putting a message away

While writing you often need another email: a date someone gave, an address, what was agreed.
**Put Away** (⇧⌘M on the Mac, the chevron at the top left on iPhone) tucks the message into a
small chip at the top of the window, so the whole app is free to search and read.

- Clicking the chip brings the message back down exactly as it was: recipients, subject, text,
  and attachments all live in `MailModel.compose` / `reply`, which stay set.
- The cross on the chip saves the message to Drafts and closes it, same as closing the composer.
- Starting another message while one is put away saves the first to Drafts, so nothing is lost
  (`MailModel.compose` `didSet` calls `saveToDrafts`).
- On the Mac the chip sits at the left of the top bar, so nothing below it moves. On iPhone it
  sits under the status bar and works for replies as well as new messages.

State: `MailModel.isComposePutAway`, `isReplyPutAway`. View: `PutAwayDraftChip` in
`WindowBar.swift`.

## From addresses and aliases

From is grouped by mailbox: each mailbox's own address first, then its aliases (Settings →
Mailboxes → a mailbox → Aliases). Aliases come from the provider, added once each so one you
remove stays removed:

- **Microsoft 365:** at launch, the mailbox's own addresses (`proxyAddresses` on `/me`, read with
  `User.Read` from the mail sign-in). Personal Microsoft accounts (outlook.com, hotmail) don't share
  theirs.
- **Gmail:** the verified "Send mail as" addresses (`users.settings.sendAs`), with the mail sign-in.
- **Everyone else** (outlook.com, iCloud, plain IMAP): by hand; their providers don't list aliases.

Automated addresses (no-reply, notifications, calendars, postmaster) are never added. Margin used
to guess aliases from Sent mail; those guesses were removed once (`aliasesFromProvidersOnly`).
Aliases also count as you: replies owed, conversations with yourself, reactions and meeting answers.

## Recipients

To, Cc and Bcc are badge fields (`RecipientField` in `Sources/MailUI/Views/RecipientField.swift`),
the same on the Mac's composer, the inline reply and iPhone and iPad. Each person is a badge
(picture and name; the address on hover); what's being typed sits after them.

- The composer still keeps each line as header text (`ComposeState.to` and friends).
  `RecipientList` (MailCore) turns that into recipients plus the bit being typed, and back, so
  what's stored is always well formed: a badge can't be half-deleted.
- A comma, a semicolon, a space after a complete address, Return, Tab or leaving the field
  finishes an address. Pasting a list makes a badge of each. Nobody is added twice.
- Suggestions (`RecipientMatches`, under the row) come from the address book and the work
  directory. The arrow keys move the highlight; Return, Tab or a click takes it; Esc puts the
  list away until more is typed.
- Backspace in an empty field picks out the last badge; again removes it. A click picks one out
  too, and each has a small cross.

## Replying to one message

The toolbar has Reply, Reply all and Forward for the conversation's latest message. Every
message also has the three next to its time (shown on a folded message when it's pointed at)
and in its ⋯ menu, for answering or forwarding that very message, however old:
`MailModel.startReply(to:all:)`, `startForward(_:)` and `Draft.reply(to:in:from:all:)`.

## Keys while writing

- ⌘⌫ clears the line being typed. It's also the menu's Move to Trash, and menus see a shortcut
  before text does, so `TextEditingKeys` (a key monitor) hands it to the text field or editor
  that has the keyboard and stops it there. Without that, clearing a line trashed the selected
  conversation.
- While a reply is being written, single-key shortcuts don't act on mail even if the list has
  the keyboard; only the arrows still move through it.
