# Updates and releases for the Mac app

The Mac app is a direct download, not on the Mac App Store, so it updates itself with
[Sparkle](https://sparkle-project.org) 2. iPhone and iPad update through the App Store as usual;
Sparkle is only in the Mac app target, never in the `MailCore` or `MailUI` packages.

**Status:** everything is in place but switched off. No release has been made, and nothing turns
on until the company's Apple Developer membership and Developer ID certificate exist (see
"One-time setup").

## What people see

- **Margin → Check for Updates…** in the menu bar, under About Margin.
- **Settings → About**, under the version: a Check for Updates… button, **Check for updates
  automatically** (on by default, about once a day) and **Download and install updates** (off by
  default; when on, updates download in the background and install when Margin quits).
- When an update is found, Sparkle's standard window shows the release notes (the GitHub release
  page) with Install, Remind Me Later and Skip This Version.
- After the update installs, Margin opens its own What's New sheet once ([changelog.md](changelog.md)).

A build without an update feed (built from source, a fork, snapshot and benchmark runs) has no
updater: no menu item and nothing in Settings.

## How it fits together

| Piece | Where |
| --- | --- |
| Updater | `Apps/macOS/Updates.swift`: starts Sparkle when `SUFeedURL` and `SUPublicEDKey` are both set, adds the menu item, and hands itself to `MailModel.updates` (`Sources/MailUI/Model/AppUpdates.swift`) for Settings → About |
| Settings | `MARGIN_UPDATE_FEED_URL` and `MARGIN_UPDATE_PUBLIC_KEY` in `Margin.local.xcconfig`, which fill `SUFeedURL` and `SUPublicEDKey` in `Apps/Margin-Info.plist`. Empty in `Margin.xcconfig`, so forks never check our feed. |
| Feed address | `https://margin.relevate.app/appcast.xml`. The site's worker (`site/worker.js`) sends it on to `appcast.xml` on the newest *published* GitHub release, so the address never changes. `https://margin.relevate.app/download/mac` does the same for `Margin.dmg`, for the website's download button. |
| Downloads | GitHub Releases on `rlvtapp/margin`: `Margin.dmg` (website and Homebrew), `Margin.zip` (what Sparkle installs), `appcast.xml`, `margin.rb` (the cask). |
| Release script | `scripts/release-mac.sh`: archive, Developer ID export, notarize and staple the app, zip it, make the disk image (`scripts/dmg/make-dmg.sh`, shared with `build-share.sh`), sign and notarize that too, sign the zip for Sparkle, write `appcast.xml` and `margin.rb`. Publishes nothing. |
| Release workflow | `.github/workflows/release-mac.yml`: runs the script when a `v*` tag is pushed and puts the files in a **draft** release. |
| Homebrew | `.github/workflows/homebrew-tap.yml`: when a release is published, copies its `margin.rb` into `rlvtapp/homebrew-tap` as `Casks/margin.rb`. Template: `scripts/homebrew/margin.rb.in`. |

Two keys keep updates safe. Apple's Developer ID signature and notarization let macOS open the app
at all. Sparkle's own EdDSA key proves an update came from us: the app carries the public half and
refuses any download not signed with the private half, even from the right address.

Sparkle compares `CFBundleVersion`. Every build's number is the date and time it was made
(`20261116.1430`, see [release.md](release.md)), so each release is higher than the one before.

## One-time setup

In this order, once the Apple Developer Program membership is active:

1. **Developer ID certificate.** In Xcode → Settings → Accounts → the company team → Manage
   Certificates, add a **Developer ID Application** certificate. Export it from Keychain Access
   as a `.p12` with a password.
2. **App Store Connect API key.** App Store Connect → Users and Access → Integrations → Team
   Keys, role **Developer**. Download the `.p8` (only possible once) and note the key id and
   issuer id. It's used to fetch the Developer ID provisioning profile (iCloud and push need one)
   and to notarize.
3. **Sparkle key.** Run Sparkle's `generate_keys` once. After any Mac build it's in
   `.build/xcode-*/SourcePackages/artifacts/sparkle/Sparkle/bin/` (or in Xcode's DerivedData under
   `SourcePackages/artifacts`). It saves the private key in the login keychain and prints the
   public key. Then `generate_keys -x sparkle-private-key` exports the private key for CI. Keep a
   copy somewhere safe: **losing it means installed copies can never update again**, and a new
   key can only reach people through a manual download.
4. **Production settings.** In `Margin.local.xcconfig`:

   ```
   MARGIN_UPDATE_FEED_URL = https:/$()/margin.relevate.app/appcast.xml
   MARGIN_UPDATE_PUBLIC_KEY = <public key from generate_keys>
   ```

5. **Website.** Deploy the site once (see [release.md](release.md)) so `/appcast.xml` and
   `/download/mac` exist.
6. **GitHub, on `rlvtapp/margin`** (Settings → Secrets and variables → Actions):

   | Secret | Value |
   | --- | --- |
   | `MARGIN_LOCAL_XCCONFIG` | The whole `Margin.local.xcconfig` |
   | `DEVELOPER_ID_CERTIFICATE` | The `.p12`, base64 (`base64 -i DeveloperID.p12 \| pbcopy`) |
   | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Its password |
   | `APP_STORE_CONNECT_KEY` | The contents of the `.p8` |
   | `SPARKLE_PRIVATE_KEY` | The contents of `sparkle-private-key` |
   | `HOMEBREW_TAP_TOKEN` | A fine-grained token with Contents read and write on `rlvtapp/homebrew-tap` only |

   | Variable | Value |
   | --- | --- |
   | `APPLE_TEAM_ID` | The company team id |
   | `APP_STORE_CONNECT_KEY_ID` | The key id |
   | `APP_STORE_CONNECT_ISSUER_ID` | The issuer id |
   | `XCODE_VERSION` | The Xcode on the runner to build with, as in its folder name (`Xcode_26.2.app` → `26.2`); at least the version Margin is developed with |

7. **Homebrew tap.** Create the public repo `rlvtapp/homebrew-tap` (the `homebrew-` prefix is
   what makes `brew tap rlvtapp/tap` work), with a README. The first published release fills it.
   Later, once Margin is well known, it can be submitted to Homebrew's main cask list so plain
   `brew install --cask margin` works.

To switch iCloud sync on for these builds as well, see [icloud.md](icloud.md) before the first
release: the Developer ID profile then needs the iCloud container too.

## Before the paid membership: development releases

Without the App Store Connect key, `scripts/release-mac.sh` makes a development release
(`DEVELOPMENT_TEAM=… scripts/release-mac.sh`): the app is signed with the Apple Development
certificate, not notarized, and the version defaults to today (`2026.11.19`, or `.1`, `.2` when
that tag is taken). The feed is GitHub's own "latest release" address,
`https://github.com/rlvtapp/margin/releases/latest/download/appcast.xml`, so nothing else has to
be deployed; drafts and prereleases are never "latest". The Sparkle key is in the login keychain
(`generate_keys -p` prints the public half, which is in `Margin.local.xcconfig`).

- **First install:** people open the disk image, drag Margin to Applications, open it, and choose
  **Open Anyway** in System Settings → Privacy & Security (once).
- **After that:** updates are found, downloaded and installed by Margin itself; every version is
  signed with the same certificate, so the Keychain items stay readable without asking.
- **Off until the paid membership:** iCloud sync and push, which need Apple's provisioning.
- Build numbers use local time everywhere (`install-mac.sh`, `build-share.sh`, releases), so a
  release is always newer than the build it replaces.

## Making a release

1. Make sure `main` is what should ship, and set nothing by hand: the script sets the version
   from the tag and the build number from the clock.
2. Tag and push the day as the version: `git tag v2026.11.19 && git push origin v2026.11.19`.
3. The **Release Mac app** workflow builds, signs, notarizes and makes a draft release with the
   four files (20–40 minutes, most of it notarization).
4. Open the draft, edit the notes (generated from the commits), and download `Margin.dmg` once to
   check it opens without warnings.
5. **Publish.** From that moment the feed and the download link point at it, Margin on people's
   Macs finds it within a day, and the Homebrew tap is updated.

A release can also be built locally with the same script (see its header for the variables);
it reads Sparkle's private key from the login keychain then.

If a release is bad, publish a fixed one with a higher version. Deleting or unpublishing a
release makes the feed fall back to the previous one, but copies that already updated stay on
the bad version until the next release.

## Installing with Homebrew

```
brew install --cask rlvtapp/tap/margin
```

The cask says `auto_updates true`, so `brew upgrade` leaves Margin to update itself; `brew
upgrade --greedy` updates it through Homebrew instead. It needs Apple silicon and macOS 15.
