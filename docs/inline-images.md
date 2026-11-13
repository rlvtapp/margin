# Pictures inside messages

**Reading.** Pictures a message shows inside its text (HTML that points at `cid:` parts) are put in
place as `data:` URLs when the body is parsed (`MessageBody.embeddingInlineImages`), so they show
with no internet access and aren't listed as attachments. JMAP accounts download those parts with
the body (up to 10 MB each). `data:` pictures aren't blocked by "load pictures from the web".

**Sending.** An `OutgoingAttachment` with a `contentID` goes into `multipart/related` next to the
HTML, with `Content-ID` and `Content-Disposition: inline`; others stay in `multipart/mixed`. The
composer's picture button adds them (`EmailHTMLWriter`, [composer.md](composer.md#formatting)).

**Code:** `MailCore/Model/Mail.swift`, `MIME/MIMEParser.swift`, `MIME/MessageBuilder.swift`,
`JMAP/JMAPProvider.swift`. Tests: `InlinePictureTests`.
