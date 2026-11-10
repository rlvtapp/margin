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
