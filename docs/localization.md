# Languages

Margin's interface is in 15 languages: US English (the source language), Canadian English,
Dutch, French, Canadian French, German, Spanish, Italian, Brazilian Portuguese, Russian,
Hungarian, Japanese, Korean, Simplified Chinese and Hindi. Margin follows the language chosen for
it in the system (Settings → Margin on iPhone and iPad; System Settings → Language & Region →
Applications on the Mac). Mail itself is never translated on its own; see "Translating mail"
below.

## Where the strings live

- `Apps/Shared/Localizable.xcstrings` is the one String Catalog, part of both the Mac and the
  iPhone/iPad app. SwiftUI text in the `MailUI` and `MailCore` packages is looked up in the app's
  main bundle, so the packages carry no catalogs of their own.
- In the packages, write text the interface shows as a literal (`Text("Inbox")`,
  `Button("Archive")`), as `LocalizedStringKey`, or as `String(localized: "…")`. Use
  `Text(verbatim:)` for anything from the user or a server: names, subjects, folder names, labels.
- Text sent to AI apps over MCP, prompts for language models, sample mail and protocol strings
  stay in English.

## Adding or changing strings

The compiler can list every localizable string:

```bash
swift build --build-path .build/loc -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/margin-loc
```

Each `.stringsdata` file in that folder is JSON with the keys of one source file. iOS-only views
(`Sources/MailUI/Touch`) only appear when building the iOS app with the same flags in
`OTHER_SWIFT_FLAGS`. New keys go into the catalog with a translation for each language. Keep every
format specifier (`%@`, `%lld`); use positional forms (`%2$@`) when a language reorders them.

Canadian English only differs in spelling (colour, centre, cancelled), so it lists just those strings.

## Changing the language

Margin follows the system language. Settings → Appearance → Language opens the place where the
system keeps each app's language (Settings → Margin on iPhone and iPad; System Settings → Language &
Region → Applications on the Mac). To try one while developing, launch with
`-AppleLanguages "(nl)"`.

## Translating mail

Messages are translated with the system's own translation, on the device: nothing goes to a
server, and it costs nothing. The first time a pair of languages is used, the system asks to
download them.

- When a message opens, `MessageTranslation.language(of:)` guesses its language from its text
  (the NaturalLanguage framework; at least 40 letters and a confident guess), and the system is
  asked whether it can translate from it. The answer is kept per message in `TranslationCache`.
- Mail in a language that isn't among the reader's preferred languages (System Settings →
  Language & Region) gets one quiet line above it: "Written in German · Translate". Settings →
  Reading → Offer to translate turns that line off.
- Translate (on that line, in the message's ⋯ menu, or in the conversation's More menu for every
  message at once) translates in place, into the reader's first language. Mail already in that
  language is left as it is.
- HTML mail is translated in its own layout (`HTMLTranslation`): the runs of text between its
  tags are taken out, translated (each distinct run once) and put back, escaped, where they were.
  Text in styles, scripts, the head and comments, and runs that are only a web or email address
  or have no letters, are left alone. Text split by inline tags (a bold word, a link) is
  translated in its pieces.
- Mail shown as text is split into paragraphs and lines first (`MessageTranslation.pieces`);
  lines wrapped at a fixed width are joined back into their sentence, and the translation keeps
  the same breaks.
- Quoted history (the mail being answered: "> …", "On … wrote:", an Outlook "From: / Sent:"
  block, a blockquote, Gmail's or Outlook's quote) isn't translated; it's already in the
  conversation. Forwarded mail is.
- Speed: when a message in another language opens and its languages are already on the device,
  the system loads its translation model straight away, so Translate starts at once. Results
  come in as they're done: text fills in every half second; HTML updates once when its opening
  part is done (each update reloads the page), then when it's finished.
- Which messages are translated lives on the model (`MailModel.translations`, kept in memory
  only), so the menus and the message agree; `TranslatableBody` draws the line and the text for
  the Mac and iPad reader and the iPhone conversation alike.
- Selected text can still be translated in the system's popover (the text actions).

Tests: `Tests/MailUITests/MessageTranslationTests.swift`.
