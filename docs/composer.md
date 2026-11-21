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
(the signature button on its row in Settings → Mailboxes): one of the mailbox's signatures, none,
or words of its own. Mail sent as it starts with that one, switching From swaps it, and an alias
without one uses the mailbox's (`MailAccount.aliasSignatureNames`, `aliasSignatures`,
`signatureChoice(sendingAs:forReply:)`). The mailbox itself can be
renamed there too (**Mailbox name**, like Work or Personal), apart from the sender name, and a
picture can be dropped onto its picture.

**Sent from Margin.** A new message, reply or forward starts with "Sent from Margin" as its last
line, under the signature, in the text you write, with "Margin" already a link to
https://margin.relevate.app in the editor (`ComposeState.sentFrom`, `RichTextEditor.linkLastLine`;
the whole line when your words don't say "Margin"). What you see is what's sent: nothing is added
or changed when you press Send, so deleting or editing the line is all it takes. Switching
mailbox swaps the signature and keeps it last, an AI draft keeps it under what's written, and a
formatted signature still replaces the plain one with the line kept after it. On by default;
Settings → Signatures turns it off or changes its words for new messages. Reactions, invitation
answers, quick replies from an alert and mail a rule sends don't get it. On iPhone and iPad the
editor is plain text, so the line is there without the link. The writing profile doesn't learn
from it.

## Signatures

Signatures can be kept in three places, each with a Default, any others ("Casual", "Formal"),
and which one replies and forwards use (`SignatureSet`):

- **All inboxes**: shared by every inbox (`SharedSignatures`, saved under "all").
- **A workspace**: shared by its inboxes, in place of the all-inboxes ones.
- **An inbox**: its own, which always come first.

An inbox without signatures of its own starts mail with its workspace's, else the all-inboxes
ones; "Use shared signatures when it has none" turns that off for one inbox
(`MailAccount.usesSharedSignatures`). An inbox with its own still lists the shared ones in the
signature menu while writing, a shared default named after where it's from
(`availableSignatures`). Shared signatures are a setting (`sharedSignatures` in the defaults,
synced and backed up like the others). The app hands each inbox the ones it falls back on
(`MailModel.applySharedSignatures`, run whenever mailboxes, workspaces or shared signatures
change) in `MailAccount.sharedSignatures`, an `Unsaved` value that's never written to disk and
never makes two mailboxes compare different, so syncing doesn't mistake it for a change.

**Settings → Signatures** (`SignaturesSettings`) shows all three and saves changes as they're
made. The copy button on a signature puts it anywhere else, as that place's default or next to
its others (a default copied this way is named after where it came from; `copySignature`). An
inbox's own list is also in Settings → Mailboxes → a mailbox. **Edit…** opens the signature in the message editor
(`SignatureSheet`), with the whole formatting bar: fonts, sizes, colours, links, alignment, lists,
and pictures (a logo, a photo). A picture is kept at most twice as wide as it's shown (300 points
at most, so 600 pixels) and can be made Small, Medium or Large. **Import HTML…** reads a signature
made elsewhere into the editor, to change from there. **Make One for Me…** and **Find in Sent
Mail** fill in the default one.

A signature is a `NamedSignature`: `text` is what the editor holds (each picture is one U+FFFC),
`html` and `pictures` are what's sent (pictures as inline `cid:` parts), and `rich` is the
formatting for the editor (an archived attributed string whose pictures point into `pictures`
by content ID, so each picture is stored once; `SignatureText`). Plain words make a plain
signature. The default one's parts are on `MailAccount` (`signature`, `signatureHTML`,
`signaturePictures`, `signatureRich`); `setSignature(_:)` changes any of them.

While writing on the Mac the signature is in the message as it's sent, pictures and all: the
composer adds its words, and the editor gives them their formatting
(`RichTextEditor.showSignature`) and marks them, so `EmailHTMLWriter` writes them as one
`margin-signature` block. A message whose HTML has that block is sent as it is. Anywhere else
(iPhone and iPad, whose editor is plain, or a signature written as HTML before this) the words
are in the message and the formatted signature takes their place when sending, with its pictures
(`MailModel.withFormattedSignature`). Text from outside (another signature from the menu, the
assistant) replaces only what changed, so what you formatted above the signature stays.

On iPhone and iPad a formatted signature shows as it's sent; changing its words there makes it
plain. A default signature written as HTML in an earlier version becomes an editable one on the
Mac once, when its HTML reads back to the same words (`upgradeFormattedSignatures`). Changing the
signature from an AI app (`set_signature`) sets plain words, and its undo puts the formatted one
back.

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

**Forgotten attachment:** before sending with nothing attached, the quick assistant reads what
you wrote (not the quoted mail) and says whether it says a file is coming with it, in any language
(`MailModel.forgotAttachment`, `MailIntelligence.mentionsAttachment`). It waits 3 seconds at most,
then sends. With AI off there's no reminder: no word list guesses it. It can be turned off in
Settings → Writing.

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

## Where the cursor starts

The editor opens with the cursor on the first line of the message, above the signature,
"Sent from Margin" and anything quoted, whether you Tab there from Subject or start a Reply,
Reply all or Forward. (Setting the text used to leave it at the very end, on the signature.)
`RichTextEditor.makeNSView` puts it at the start, so the signature editor in Settings starts
at the top too. iPhone and iPad use the system's plain text editor, unchanged. Test:
`ReplySizeTests.writingStartsOnTheFirstLineAboveTheSignature`.

## Writing a reply bigger (Mac)

The expand button (arrows pointing out, ⇧⌘E) in the reply's tools makes the reply fill the
reading pane, in the same place, with no other window. The reply grows to the height of the
pane and scrolls into view, with a strip of the conversation showing above it; scrolling up
reads the whole conversation. The same button (arrows pointing in), ⇧⌘E or Esc makes it its
usual size again. After that, Esc closes the reply as before and keeps it in Drafts.

- The reply's editor stays where it is in the reader's scroll view and only changes height
  (`ReplyEditor.expandedHeight`), so the text, the cursor and the formatting are untouched.
  The button's symbol changes inside its own frame, so the tools don't shift.
- It grows and scrolls with `Motion.present`. With Reduce Motion it changes at once.
- A new reply, and one that's sent, closed or discarded, starts at its usual size
  (`MailModel.isReplyExpanded`, reset in `reply`'s `didSet`). Choosing another conversation
  clears the reply bar, as before.
- A new message already fills the reading pane, so it has no such button. On iPhone and iPad
  a reply opens full screen anyway.
- Code: `MailModel+ReplySize.swift`, `ReplyEditor` in `ComposeViews.swift`, `ReaderView`.
  Tests: `ReplySizeTests`.

## Attachments

Drop files on the message or use the paperclip. Mail can carry about 25 MB in all
(`ComposeAttachments.sizeLimit`, the common provider limit): files that would go over it, or that
can't be read, aren't attached, and a red line under the attachments names them and suggests
sharing big files by link; it goes at the next try or with ✕.

In a received message, an attachment's menu has **Quick Look** (a preview in place, never
running anything, so it's safe for apps and scripts too), Open and Save As…; a message with more
than one file has **Save All…**, which asks for a folder once (Downloads to start), saves each
file marked as downloaded, and numbers names that are taken ("report 2.pdf") rather than
overwriting.

## Sending and Undo Send

Send closes the composer at once and the message waits out the Undo Send delay (Settings, 5
seconds by default) before it goes: `MailModel.queueSend`.

- **One notice the whole way.** The pill at the bottom says "Sending…" with a ring that fills
  and **Undo** (Z on the Mac). When the ring is full Undo fades out; once the message is out the
  same pill changes in place to "Sent from" and the mailbox (or the alias address it went out
  from), and a tick draws into the full ring. It never leaves and comes back in between: the
  model keeps the same notice (`Notice.isSent`, `Notice.countdown`) and `NoticeBar` doesn't time
  it out while it's still sending. The text interpolates and the pill's width springs to fit
  (`Motion.present`); with Reduce Motion it's a short fade, without the slide or the tick's scale.
- **Undo** cancels the send before anything reaches the server (`undoSend`: the task is
  cancelled and `pendingSend` cleared in one main-actor step, so it can't also go out) and opens
  the message again exactly as it was: recipients, Cc and Bcc, subject, text, formatting and
  pictures, attachments, the from address, the reply or forward it belongs to, a reminder, and
  the saved draft it came from. It's never put in the outbox. A reply goes back to the reply bar
  when its conversation is still open, otherwise to the composer (still a reply). A message
  started in that spot meanwhile is saved to Drafts first, so nothing is written over.
- **Formatting comes back too.** The Mac editor starts from the message's HTML when there is
  some and reading it back gives the same words (`EditorStart`), so bold, links and inline
  pictures survive Undo and a failed send. Otherwise it starts from the plain words, as before.
- Sending a second message while one is still waiting sends the first at once (`deliver`); if
  that fails it reopens like any failed send. Offline, a message waits in the outbox instead.
- **Probably sent.** When the whole message reached the server and the connection broke before
  the server confirmed it (`MailError.deliveryUnconfirmed`, raised by `SMTPClient.send` after
  the final dot), it was most likely delivered. It's never reopened as failed, put in the
  outbox or sent again by itself, which would deliver it twice. A copy goes to Drafts and the
  notice says to check Sent before sending it again (`keepUnconfirmed`). The same goes for an
  outbox message, which leaves the outbox. An AI app sending through Margin gets that notice as
  its answer. Only plain SMTP sending tells this apart; Microsoft 365 and JMAP don't yet.
- Tests: `UndoSendTests`, `UnconfirmedSendTests`, and the SMTP drop cases in `LiveProtocolTests`.

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
