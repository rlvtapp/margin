#!/bin/zsh
# Makes everything one Mac release needs, in .build/release/<version>/ (docs/updates.md):
#   Margin.dmg     the download for the website, signed (and notarized with the paid membership)
#   Margin.zip     what the updater downloads, holding the same notarized app
#   appcast.xml    the update feed, listing this version and its Sparkle signature
# It publishes nothing: the files go up to a GitHub release by hand (docs/updates.md).
#
#   MARGIN_VERSION=2026.11.19 DEVELOPMENT_TEAM=ABCDE12345 \
#   NOTARY_KEY_PATH=~/keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER_ID=… \
#   scripts/release-mac.sh
#
# Without the NOTARY_* keys (before the paid Apple membership), it makes a development release:
# signed with your Apple Development certificate, not notarized. People choose Open Anyway once
# (System Settings → Privacy & Security); every update after that installs by itself.
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/release-mac.sh
# MARGIN_VERSION defaults to today (2026.11.19), or the next free one (2026.11.19.1) when today's
# tag is taken.
#
# Needs a Developer ID Application certificate in the keychain, and Margin.local.xcconfig with the
# production values, MARGIN_UPDATE_FEED_URL and MARGIN_UPDATE_PUBLIC_KEY among them. The App
# Store Connect key signs in for the provisioning profile and for notarization. Sparkle's private
# key comes from the login keychain, or from SPARKLE_PRIVATE_KEY when set (on CI).
set -euo pipefail
ROOT=${0:A:h:h}
: ${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple developer team id}
# Notarized (Developer ID) when the App Store Connect key is given; otherwise a development release.
NOTARIZE=${NOTARY_KEY_PATH:+yes}
if [[ -n $NOTARIZE ]]; then
  : ${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to that key id}
  : ${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID to the key issuer id}
fi
if [[ -z ${MARGIN_VERSION:-} ]]; then
  MARGIN_VERSION=$(date +%Y.%-m.%-d)
  next=1
  base=$MARGIN_VERSION
  while git -C "$ROOT" rev-parse -q --verify "refs/tags/v$MARGIN_VERSION" >/dev/null \
    || gh release view "v$MARGIN_VERSION" --repo "${MARGIN_GITHUB_REPO:-rlvtapp/margin}" >/dev/null 2>&1; do
    MARGIN_VERSION=$base.$next
    next=$((next + 1))
  done
fi
REPO=${MARGIN_GITHUB_REPO:-rlvtapp/margin}
DOWNLOADS=${MARGIN_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$MARGIN_VERSION}
# Same scheme as every other build (docs/release.md): the date and time, which also keeps each
# release's number higher than the last, as Sparkle needs.
BUILD=${MARGIN_BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}
OUT=$ROOT/.build/release/$MARGIN_VERSION
DATA=$ROOT/.build/xcode-release
ARCHIVE=$OUT/Margin.xcarchive
EXPORTED=$OUT/export
typeset -a AUTH NOTARY
if [[ -n $NOTARIZE ]]; then
  AUTH=(-authenticationKeyPath "$NOTARY_KEY_PATH" -authenticationKeyID "$NOTARY_KEY_ID" -authenticationKeyIssuerID "$NOTARY_ISSUER_ID")
  NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

rm -rf "$OUT"
mkdir -p "$OUT"
log() { print -P "%B$1%b" }

log "Archiving Margin $MARGIN_VERSION ($BUILD)"
if ! xcodebuild -project "$ROOT/Apps/Margin.xcodeproj" -scheme "Margin (Release)" -destination 'generic/platform=macOS' \
  -derivedDataPath "$DATA" -archivePath "$ARCHIVE" -allowProvisioningUpdates "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development" MARKETING_VERSION="$MARGIN_VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive > "$OUT/archive.log" 2>&1; then
  tail -n 80 "$OUT/archive.log"
  exit 1
fi

# A release that can't update itself would strand everyone on it.
INFO=$ARCHIVE/Products/Applications/Margin.app/Contents/Info.plist
FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO" 2>/dev/null || true)
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO" 2>/dev/null || true)
if [[ -z $FEED || -z $PUBLIC_KEY ]]; then
  print "MARGIN_UPDATE_FEED_URL and MARGIN_UPDATE_PUBLIC_KEY must be set in Margin.local.xcconfig."
  exit 1
fi

if [[ -n $NOTARIZE ]]; then
log "Signing with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
PLIST
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORTED" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates "${AUTH[@]}" > "$OUT/export.log" 2>&1; then
  tail -n 80 "$OUT/export.log"
  exit 1
fi
APP=$EXPORTED/Margin.app
codesign --verify --deep --strict "$APP"

log "Notarizing the app"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"
else
  # A development release: the archived app, signed with your Apple Development certificate.
  log "Development release: signed with your certificate, not notarized"
  APP=$ARCHIVE/Products/Applications/Margin.app
  codesign --verify --deep --strict "$APP"
fi

# The updater gets a zip of the app; the website gets the disk image.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Margin.zip"

log "Making the disk image"
"$ROOT/scripts/dmg/make-dmg.sh" "$APP" "$OUT/Margin.dmg"
if [[ -n $NOTARIZE ]]; then
  IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=Developer ID Application/ && !found {print $2; found=1}')
  codesign --sign "$IDENTITY" --timestamp "$OUT/Margin.dmg"
  xcrun notarytool submit "$OUT/Margin.dmg" "${NOTARY[@]}" --wait
  xcrun stapler staple "$OUT/Margin.dmg"
  spctl --assess --type open --context context:primary-signature "$OUT/Margin.dmg"
else
  IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=Apple Development/ && !found {print $2; found=1}')
  codesign --sign "$IDENTITY" "$OUT/Margin.dmg"
fi

log "Signing the update"
SIGN_UPDATE=$DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
if [[ -n ${SPARKLE_PRIVATE_KEY:-} ]]; then
  ENCLOSURE=$(print -rn -- "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$OUT/Margin.zip")
else
  ENCLOSURE=$("$SIGN_UPDATE" "$OUT/Margin.zip")
fi
# sign_update prints: sparkle:edSignature="…" length="…"
[[ $ENCLOSURE == *edSignature=* ]] || { print "sign_update gave no signature: $ENCLOSURE"; exit 1; }

MINIMUM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
# What's New for this version, in each language, shown in the update window (docs/changelog.md).
NOTES=$("$ROOT/scripts/release-notes.py" "$MARGIN_VERSION")
[[ -n $NOTES ]] || print "No What's New notes for $MARGIN_VERSION; the update window shows none."
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Margin</title>
    <item>
      <title>Margin $MARGIN_VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$MARGIN_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
$NOTES
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$MARGIN_VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$DOWNLOADS/Margin.zip" type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML

rm -rf "$EXPORTED" "$ARCHIVE"
print "Version $MARGIN_VERSION (build $BUILD)"
log "Done: $OUT"
ls -la "$OUT" | awk 'NR > 1 {print $5, $9}'
