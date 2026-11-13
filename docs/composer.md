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

Add an address straight from the From menu (**Add an Address…**): it's added to the mailbox's
Send as list and used for the message at once. Each send-as address can have **its own signature**
(the signature button on its row in Settings → Mailboxes); mail sent as it starts with that one,
switching From swaps it, and an alias without one uses the mailbox's
(`MailAccount.aliasSignatures`, `signature(sendingAs:forReply:)`). The mailbox itself can be
renamed there too (**Mailbox name**, like Work or Personal), apart from the sender name, and a
picture can be dropped onto its picture.

**Sent from Margin.** A new message, reply or forward starts with "Sent from Margin" as its last
line, under the signature, in the text you write, with "Margin" already a link to
https://margin.relevate.app in the editor (`ComposeState.sentFrom`, `RichTextEditor.linkLastLine`;
the whole line when your words don't say "Margin"). What you see is what's sent: nothing is added
or changed when you press Send, so deleting or editing the line is all it takes. Switching
mailbox swaps the signature and keeps it last, an AI draft keeps it under what's written, and a
formatted signature still replaces the plain one with the line kept after it. On by default;
Settings → Writing turns it off or changes its words for new messages. Reactions, invitation
answers, quick replies from an alert and mail a rule sends don't get it. On iPhone and iPad the
editor is plain text, so the line is there without the link. The writing profile doesn't learn
from it.

## Forwarding with formatting

Forwarding an HTML email carries it underneath what you write, as it came: colours, tables, links
and pictures. The composer shows it folded under the message ("Forwarded email · Goes out with its
own formatting"); **Edit as Text** turns it into quoted text in the message instead, to trim it.
Plain-text mail is quoted as text, as before. The original's `<head>`, scripts and `cid:` pictures
(which don't travel with a forward) are left out, its styles kept (`ForwardedOriginal`). It goes out
in the HTML part, with a quoted copy in the plain part, also from saved drafts and Send later.
Replies still quote nothing: the conversation is on the page. A message's own Reply opens the
reply box right under that message when it isn't the last one; the toolbar's Reply keeps it at the
bottom (`ComposeState.answersOneMessage`).

## Formatting

The formatting bar (`FormattingBar`, `RichTextController`) sits on top, right above the text, in
the Mac's composer (under Subject) and in the reply. **Aa** hides or shows it, and the choice is
remembered for the next message (`showsFormattingBar`, on by default). It has undo and redo; font (the normal one, seven that look the same on most devices, and Show
Fonts… for any font on the Mac) and size (10 to 36 points); bold, italic, underline,
strikethrough; text colour and highlight in Relevate's nine named colours (gray, brown, orange,
yellow, green, blue, purple, pink, red, the set its web editor uses); alignment, bulleted and
numbered lists, indent and outdent, line spacing (single, 1.15, 1.5, double); a link, a picture
inside the text (shown at most 480 points wide), the emoji picker; and clear formatting, which
keeps links and pictures. Mail stays plain until something is formatted.

What's sent is written by Margin's own `EmailHTMLWriter`, not the system's HTML writer: every style
sits on its element (mail apps drop `<style>` blocks, which the system's writer relies on), line
spacing and indents are kept (the system's writer drops line spacing), and a picture goes out as
an inline part (`cid:`, `multipart/related`) named by its bytes, so writing the HTML again never
adds a copy; deleting it from the text takes it out of the draft. The plain-text part leaves the
picture's placeholder character out. The editor's normal text colour follows dark mode, so it's
left out of the HTML: white text never reaches someone reading on white. On iPhone and iPad the
editor is plain text.

The block editor that used to be in Settings → Experimental is gone: Margin has no dependency on
Relevate's native editor, and the composer above is the one editor.

The forgotten-attachment reminder can be turned off in Settings → Writing.

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
