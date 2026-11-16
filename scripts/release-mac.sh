#!/bin/zsh
# Makes everything one Mac release needs, in .build/release/<version>/ (docs/updates.md):
#   Margin.dmg     the download for the website and Homebrew, signed and notarized
#   Margin.zip     what the updater downloads, holding the same notarized app
#   appcast.xml    the update feed, listing this version and its Sparkle signature
#   margin.rb      the Homebrew cask for this version
# It publishes nothing: .github/workflows/release-mac.yml uploads these to the GitHub release.
#
#   MARGIN_VERSION=0.2.0 DEVELOPMENT_TEAM=ABCDE12345 \
#   NOTARY_KEY_PATH=~/keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER_ID=… \
#   scripts/release-mac.sh
#
# Needs a Developer ID Application certificate in the keychain, and Margin.local.xcconfig with the
# production values, MARGIN_UPDATE_FEED_URL and MARGIN_UPDATE_PUBLIC_KEY among them. The App
# Store Connect key signs in for the provisioning profile and for notarization. Sparkle's private
# key comes from the login keychain, or from SPARKLE_PRIVATE_KEY when set (on CI).
set -euo pipefail
ROOT=${0:A:h:h}
: ${MARGIN_VERSION:?Set MARGIN_VERSION to the version being released, like 0.2.0}
: ${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the company Apple developer team id}
: ${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH to the App Store Connect API key (.p8)}
: ${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to that key id}
: ${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID to the key issuer id}
REPO=${MARGIN_GITHUB_REPO:-rlvtapp/margin}
DOWNLOADS=${MARGIN_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$MARGIN_VERSION}
# Same scheme as every other build (docs/release.md): the date and time, which also keeps each
# release's number higher than the last, as Sparkle needs.
BUILD=${MARGIN_BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}
OUT=$ROOT/.build/release/$MARGIN_VERSION
DATA=$ROOT/.build/xcode-release
ARCHIVE=$OUT/Margin.xcarchive
EXPORTED=$OUT/export
AUTH=(-authenticationKeyPath "$NOTARY_KEY_PATH" -authenticationKeyID "$NOTARY_KEY_ID" -authenticationKeyIssuerID "$NOTARY_ISSUER_ID")
NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

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

# The updater gets a zip of the stapled app; the website and Homebrew get the disk image.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Margin.zip"

log "Making the disk image"
"$ROOT/scripts/dmg/make-dmg.sh" "$APP" "$OUT/Margin.dmg"
IDENTITY=$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=Developer ID Application/ {print $2; exit}')
codesign --sign "$IDENTITY" --timestamp "$OUT/Margin.dmg"
xcrun notarytool submit "$OUT/Margin.dmg" "${NOTARY[@]}" --wait
xcrun stapler staple "$OUT/Margin.dmg"
spctl --assess --type open --context context:primary-signature "$OUT/Margin.dmg"

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
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$MARGIN_VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$DOWNLOADS/Margin.zip" type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML

log "Writing the Homebrew cask"
DMG_SHA=$(shasum -a 256 "$OUT/Margin.dmg" | awk '{print $1}')
sed -e "s|@VERSION@|$MARGIN_VERSION|g" -e "s|@SHA256@|$DMG_SHA|g" -e "s|@REPO@|$REPO|g" \
  "$ROOT/scripts/homebrew/margin.rb.in" > "$OUT/margin.rb"

rm -rf "$EXPORTED"
log "Done: $OUT"
ls -la "$OUT" | awk 'NR > 1 {print $5, $9}'
