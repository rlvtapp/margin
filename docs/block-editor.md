# Block editor in the composer (experimental)

Settings → Experimental → **Block editor in the composer**, off by default. The full composers
(the Mac compose window, and new messages on iPhone and iPad) then use Relevate's native block
editor, the same one Daybook uses for meeting notes:

- **`/` menu** for text, three heading sizes, bulleted and numbered lists, checklists, quotes,
  callouts, code, dividers, tables and pictures. Pages and databases aren't offered.
- **Pictures** (from the menu, pasted or dropped) go out inside the message at that spot:
  `multipart/related` with a Content-ID per picture, `<img src="cid:…">` in the HTML, at most 600
  pixels wide, large ones made smaller and HEIC sent as JPEG. The plain-text part says
  `[Picture]`. Files added with the paperclip stay ordinary attachments.
- **Drag blocks** by their handle to reorder them.
- Bold, italic, strikethrough, underline, inline code and links.
- **Pasting formatted text** from other apps keeps its structure: rich text from Notes, Pages or
  Word and HTML from web pages and online documents become headings, bulleted and numbered lists
  (with nesting), checklists (☐/☑ or [ ]/[x]), quotes, code and styled text. Plain text pastes as
  before. (The converter is the editor's `RichPaste`, so Daybook and Relevate get it too.)
- Quick replies keep the simple editor. On iPhone and iPad the editor's bar sits above the
  keyboard; Margin's attach and send-later row is at the foot.

## What gets sent

The editor's blocks become a `MailDocument` and go out as standard email: common tags with inline
styles only (no classes, stylesheet or scripts), so it looks the same in every mail app, plus a
plain-text part that keeps the structure (`## Heading`, `- item`, `[ ] task`, `> quote`).
Headings are sent as `h2`–`h4`, checklists as ☐/☑, callouts as quotes. A message without structure
is sent as plain text. The signature stays outside the editor and is added after it, formatted or
plain.

## Building

The editor comes from `../goud-monorepo/packages/editor-next/apple` (a local Swift package, as in
Daybook), so Margin needs that checkout beside it and builds for Apple silicon (arm64) only.
`NativeBlockEditor` takes `allowedBlocks` to limit what the menu offers.

**Code:** `MailUI/Views/BlockComposer.swift`, `MailCore/Compose/MailDocument.swift`,
`MailModel.applying`. Tests: `MailDocumentTests`, `BlockComposerTests`, `EditorBlocksToEmailTests`.
