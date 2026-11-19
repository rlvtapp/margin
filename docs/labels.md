# Labels

Margin has two kinds of labels, shown the same way: chips on list rows and under the subject in the reader.

- **Margin's own labels** live on the device (`LabelStore`, synced over iCloud with the rest). Any account can have them. Groups on Home are labels of this kind.
- **Server labels** belong to accounts whose server keeps labels: IMAP servers that keep labels instead of folders (the Gmail account type), and Graph accounts, whose categories are labels without folders of their own (`GraphMailProvider`). A message carries any number of them and shows in each label's folder. Margin reads and changes them on the server, so they match the provider's own apps.

## Server labels over IMAP

A server that keeps labels says so with the `X-GM-EXT-1` capability (`IMAPClient.supportsLabels`). The code is in `Sources/MailCore/IMAP/IMAPLabels.swift`.

- **Reading.** List fetches also ask for `X-GM-LABELS`, `X-GM-THRID` and `X-GM-MSGID`. They become `MailMessage.labels`, `threadID` and `serverID`. The two ids are unsigned 64-bit numbers, so they're kept as text. Label names come in modified UTF-7, like folder names, and are decoded. System labels keep their backslash (`\Inbox`, `\Important`, `\Sent`). The server is taken to leave the selected folder's own label out of each answer (not yet tried against a live account), so Margin adds it back (`IMAPLabels.adding`). Checks of known mail ask for `(UID FLAGS X-GM-LABELS)`, so labels changed elsewhere arrive with flag changes. Messages saved before labels were read get theirs once.
- **Folders are labels.** Every listed folder gets the label it stands for (`Mailbox.label`): the inbox is `\Inbox`, Sent `\Sent`, Drafts `\Draft`, Starred `\Starred`, the folder marked `\Important` is `\Important`, and the person's own folders are their own name ("Projects/2026"). All Mail, Trash and Spam have none: mail goes there by moving.
- **Changing.** `UID STORE … +X-GM-LABELS.SILENT (…)` adds and `-X-GM-LABELS.SILENT (…)` takes off (`IMAPLabels.store`). System labels go bare and the person's own labels go quoted and encoded. The change is made in All Mail rather than in the folder on screen, assuming (not yet tried against a live account) that a folder may not change the label it stands for on its own copies. Margin finds each message there with `UID SEARCH X-GM-MSGID …` (`IMAPLabels.search`) and stores on those UIDs. The remembered folder state follows at once, so the next check doesn't bring back the old labels.
- **Actions** (`IMAPProvider.labelChange`):
  - **Done** takes `\Inbox` off. The mail stays in All Mail with its other labels.
  - **Move to inbox** puts `\Inbox` back.
  - **Move** to a label adds that label and takes off the label of the folder it came from. Moving to All Mail only takes the old label off.
  - **Trash, Junk and Not junk** stay real moves, and so does anything moved out of Trash or Spam.
  - A move takes off only `\Inbox` or the person's own label. Sent, Starred and Important stay.
  - Mail that can't be found in All Mail (no server id saved, or no All Mail folder) gets the usual moves instead.
  - Done in a label's folder takes off only `\Inbox`, as on the provider's own apps: the conversation stays in that label and shows there again at the next check.
- **Adding and removing** a label is `MailProvider.changeLabel(_:adding:on:)`. Providers without labels inherit a default that throws `notSupported`.
- **Conversations.** `Threader` joins messages that share a `threadID` before it looks at reply headers. A message that arrives from two folders (the inbox and All Mail, as in search) is kept once, by `serverID`.

## In the app

- **Chips.** `MailModel.labels(for:)` puts the server's own labels first, then Margin's. System labels aren't shown. Rows leave out the label of the folder on screen, since every row there has it (`rowLabels(for:)`). A chip's ✕ (and the assistant's `remove_label` tool) takes the label off on the server; Margin's own removals, such as taking a conversation out of a Home group, only touch its own labels.
- **Adding.** A label the person adds (the reader's Add a label, a suggested label, the assistant's `add_label` tool) goes to the server on these accounts (`addLabel(_:to:onServer:)`). Labels Margin gives on its own, such as Home groups, rules and the Tasks label from reminders, stay on the device, so they don't fill the person's label list on the server. A new name creates the label on the server. A name that differs only in case joins the existing label.
- **Which accounts.** `MailModel.keepsLabels` is true for Graph accounts and for accounts whose folders stand for labels (`foldersAreLabels`). Only the second kind gets the sidebar changes below.
- **Sidebar.** On accounts whose folders are labels, the Folders section is called Labels. Each label shows as a tag in its colour, nested by "/" (folded until opened), with the usual Rename, Hide and Delete, and a Color menu. Creating a folder there creates a label.
- **Colours.** IMAP has no label colours. On accounts that sign in through the provider's own sign-in page, Margin reads them from the provider's label list over HTTPS with the same sign-in (`IMAPLabels.labelListURL`), at most hourly. A failure leaves them out. Each colour becomes the nearest colour of Margin's own palette, so text on the chip stays readable (`LabelColors.server`). A colour picked from the Color menu wins.

## Pictures

`-snapshot-labels` (with `-snapshot-mailbox 0`) makes the sample mailbox keep labels, with nested and coloured ones, and puts some on its inbox mail (`MailModel.addSampleLabels`).

```
Margin.app/Contents/MacOS/Margin -snapshot labels.png -snapshot-mailbox 0 -snapshot-labels -snapshot-select "…"
```
