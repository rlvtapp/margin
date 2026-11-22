# Languages

Margin's interface is in 19 locales: US English (the source language), Canadian English,
Dutch, French, Canadian French, German, Spanish, Italian, Brazilian Portuguese, Russian,
Hungarian, Japanese, Korean, Simplified Chinese, Traditional Chinese, Hindi, Turkish, Polish and
Swedish. Margin follows the language chosen for
it in the system (Settings → Margin on iPhone and iPad; System Settings → Language & Region →
Applications on the Mac). Mail itself is never translated on its own; see "Translating mail"
below.

## Where the strings live

- `Apps/Shared/<locale>.lproj/` holds general translations, one folder per language, shared by the
  Mac, iPhone/iPad and Watch targets through Xcode variant groups.
  SwiftUI text in the `MailUI` and `MailCore` packages is looked up in the app's main bundle.
  These are native Apple resources; no generated catalog or extra build step is needed.
- `Localizable.strings` holds general interface text and labels passed through shared controls.
  `Settings.strings`, `Calendar.strings` and `Composer.strings` hold those features' text.
  `Apps/Shared/Changelogs/<locale>.lproj/Changelog-<version>.strings` holds one release's
  titles and descriptions. Version files stay in the Changelogs folder; the update feed reads
  that release's table too, including when a later build reuses its notes.
  A key used by several features belongs in each table that looks it up. Keep its general-table
  entry while any shared control or other screen still looks it up there.
- Feature lookups specify their table: `String(localized: "…", table: "Calendar")` or
  `Text("…", tableName: "Calendar")`. SwiftUI controls without a table argument can use a
  localized String, such as `Button(String(localized: "Send", table: "Composer")) { … }`.
  Keep `Text(verbatim:)` for text from the user or server.
- Split further by feature when a feature has a substantial set of its own strings. Each table
  needs an explicit lookup at its call sites (`table:` for Foundation, `tableName:` for SwiftUI)
  and a variant group in all three app targets. Moving files alone does not change lookups.
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
`OTHER_SWIFT_FLAGS`. Add new keys to the appropriate English table and a translation to
each language's matching table, keeping entries sorted by key. Each entry is one `"English key" = "Translation";`
line; translator comments go directly above it. Escape quotes as `\"` and newlines as `\n`.
Keep every format specifier (`%@`, `%lld`); use positional forms (`%2$@`) when a language reorders them.

Canadian English only differs in spelling (colour, centre, cancelled), so it lists just those strings.

Validate an edited file with `plutil -lint Apps/Shared/<locale>.lproj/Localizable.strings`.
Run `python3 scripts/check-localizations.py` to validate all tables. After compiler extraction,
`python3 scripts/check-localizations.py --extracted-strings /tmp/margin-loc` also checks that
feature lookups have entries in the matching English table. Extract Mac and iOS builds into
separate directories and check both to cover platform-specific text.
When adding a locale, also add it to every table's variant group and the project's
known regions. `scripts/release-notes.py` reads `Changelog-<version>.strings` for translated
update notes. Use the version of the notes, which may be earlier than the build being released.

## Changing the language

Margin follows the system language unless told otherwise. On the Mac, Settings → General →
Language is a menu: **Same as Mac**, then every language Margin is translated into, each named in
itself. Picking one saves it as Margin's own `AppleLanguages` (the same place System Settings →
Language & Region → Applications writes), and **Restart Margin** appears beside it, since a
language is read when Margin starts (`LanguageSetting`). Restarting quits this Margin first, the
usual way (anything waiting to reach a server is still sent), and a small helper opens Margin
again once it has gone, so there is never a second Margin beside the first, and it comes back in
the Dock icon it was in (`Relaunch`). If Margin hasn't quit within a minute, because the quit was
stopped, the helper gives up rather than opening Margin later. Same as Mac removes it again. On iPhone
and iPad, Settings → General → Language opens Settings → Margin, where iOS keeps it. To try one while developing, launch with
`-AppleLanguages "(nl)"`.

## Translating mail

Messages are translated with the system's own translation, on the device: nothing goes to a
server, and it costs nothing. The first time a pair of languages is used, the system asks to
download them.

- When a message opens, `MessageTranslation.language(of:)` guesses its language from its text
  (the NaturalLanguage framework), and the system is asked whether it can translate from it. The
  answer is kept per message in `TranslationCache`. The recognizer settles on about the first
  hundred characters it's given, and a newsletter's opening (a product name, a headline, a
  divider) plus its links and address footer can read as Indonesian or Polish on their own. So
  web and mail addresses, tracking codes, paths, numbers, acronyms and words with capitals inside
  are left out, quoted lines too; what's left (at least 40 letters) is read in runs of about 70
  letters through the first 8,000 characters, and each run's guesses count for its letters. A
  language the reader reads wins with 30% of the message; any other needs 75%, or no language is
  given and no line shows.
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
