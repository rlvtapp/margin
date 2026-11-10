# Languages

Margin's interface is in 15 languages: US English (the source language), Canadian English,
Dutch, French, Canadian French, German, Spanish, Italian, Brazilian Portuguese, Russian,
Hungarian, Japanese, Korean, Simplified Chinese and Hindi. Margin follows the language chosen for
it in the system (Settings → Margin on iPhone and iPad; System Settings → Language & Region →
Applications on the Mac). Mail itself is never translated; use Translate in a conversation's
menu for that.

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
