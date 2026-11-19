# Changelog (What's New)

Margin keeps a short list of what changed in each version, inside the app.

## What people see

- **Once after an update**, a What's New sheet opens with the new version's notes: the app icon,
  a few rows (a coloured symbol, a short title, one sentence) and Continue. Earlier versions are
  folded below.
- **Settings → What's New**, the page above About, lists every version, newest first, each under
  its date, with "This version" on the one running. Searching Settings for "changelog" or
  "release notes" finds it.
- **Versions are dates:** a version is the day it's released, `2026.11.19`
  (`CFBundleShortVersionString`, docs/release.md). The page shows "Version 2026.11.19" with the
  day written out beside it; About shows the version, and the build number on hover.
- A fresh install gets the welcome instead; the version is noted as seen either way, so the
  notes never open on top of the welcome. Moving to an older version, or a version without
  notes, opens nothing.

## Adding a release's notes

1. In `Sources/MailUI/Model/Changelog.swift`, add a `ChangelogRelease` at the top of
   `Changelog.releases` with the version it ships in (`"2026.11.26"`). Every version from then on
   has them; the sheet opens once on the first version with notes newer than the one seen last.
2. Three to six changes people will notice, written for them: what it does for you, not how it
   works. One SF Symbol and an account colour (`hue`) each.
3. Every title and sentence is `String(localized:)`, so translate them like any other string
   ([localization.md](localization.md)). Notes that aren't translated show in English.
4. Tag and release as in [updates.md](updates.md). The GitHub release notes can be copied from
   the same lines.

`ChangelogTests` checks the list stays newest first and that the sheet opens only after an update.

## Code

| Piece | Where |
| --- | --- |
| Notes and the "opens once" rule | `Sources/MailUI/Model/Changelog.swift` (`Changelog`, `showChangelogIfUpdated`, defaults key `changelog.seen`) |
| The sheet and the page | `Sources/MailUI/Views/WhatsNewView.swift` (`WhatsNewView` from `MailRootView`'s `isShowingWhatsNew`; `ChangelogSettings` for Settings → What's New) |
| Snapshot | `-snapshot-whats-new` in `Apps/macOS/SnapshotMode.swift` |
