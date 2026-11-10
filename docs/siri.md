# Siri and Apple Intelligence

Margin adopts Apple's mail App Intents schemas, so Siri understands its mail the way it
understands Apple Mail. Code: `Sources/MailUI/Siri/`.

- **Entities** (`@AppEntity(schema: .mail.message / .mail.account / .mail.mailbox)`): each inbox
  conversation is a mail message entity (its newest message), built from mail on the device.
  Messages are also an `IndexedEntity`, indexed into Spotlight after every check for mail.
- **On screen:** the reader marks the open conversation with an `NSUserActivity` carrying its
  `appEntityIdentifier`, so "summarize this" or "archive this" knows what "this" is.
- **Actions** (`@AppIntent(schema: .mail.…)`): archive, delete, update (read, star, move),
  reply and forward. Reply and forward open the composer with what Siri was asked to write;
  nothing is sent without the person.
- **Status:** built and validated against the iOS/macOS 27.2 SDK (the App Intents metadata
  processor checks each schema's required properties at build time). Apple's 27.3 release opens
  these schemas to third-party apps in Siri; with the 27.3 betas apps can be tested in Xcode and
  internal TestFlight but not shipped to the App Store yet.

## Sign-in codes

When a mail with a sign-in code arrives, Margin copies the code to the clipboard (Settings →
Reading → Sign-in codes) and its notification shows the code with a Copy button, whatever the
alert setting. The keyboard's own code suggestions (QuickType AutoFill) only read Messages and
Apple Mail, so a third-party app can't put a code there; the clipboard is the next best thing.
