#!/bin/zsh
# Makes a Mac build to hand to someone: .build/share/Margin-mac-<build>.dmg (the app with a
# shortcut to Applications beside it, to drag it in) and Margin-mac-<build>.zip. It's signed with
# your development certificate, not notarized: the first time, they open it, then choose Open
# Anyway in System Settings → Privacy & Security. Signed by a certificate (not ad hoc), every new
# version is the same app to macOS, so its Keychain items stay readable without asking.
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/build-share.sh
# The disk image opens as a laid-out window (scripts/dmg/make-dmg.sh).
set -euo pipefail
ROOT=${0:A:h:h}
OUT=${MARGIN_SHARE_OUT:-$ROOT/.build/share}
DATA=${MARGIN_SHARE_DATA:-$ROOT/.build/xcode-share}
IMAGE=$(mktemp -d)
trap 'rm -rf $IMAGE' EXIT

mkdir -p "$OUT"
# Every build gets a number of its own, the date and time it was made (20261112.1742), shown
# in Settings → About next to the version and in the files' names. MARGIN_BUILD_NUMBER sets another.
BUILD=${MARGIN_BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}
# The version is the day (docs/release.md).
VERSION=${MARGIN_VERSION:-$(date +%Y.%-m.%-d)}
: ${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple developer team id}
typeset -a version_settings
version_settings=("MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD")

# A failed compile must never package the previous app left in DerivedData.
if ! xcodebuild -project "$ROOT/Apps/Margin.xcodeproj" -scheme "Margin (Release)" -destination 'platform=macOS' -derivedDataPath "$DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development" \
  "${version_settings[@]}" build > "$OUT/build.log" 2>&1; then
  tail -n 80 "$OUT/build.log"
  exit 1
fi
print "BUILD SUCCEEDED"

ditto "$DATA/Build/Products/Release/Margin.app" "$IMAGE/Margin.app"
codesign --verify --deep --strict "$IMAGE/Margin.app"

mkdir -p "$OUT"
# Only the newest build stays, so an old file is never sent by mistake.
rm -f "$OUT"/Margin-mac*.dmg(N) "$OUT"/Margin-mac*.zip(N)
(cd "$IMAGE" && ditto -c -k --sequesterRsrc --keepParent Margin.app "$OUT/Margin-mac-$BUILD.zip")

"$ROOT/scripts/dmg/make-dmg.sh" "$IMAGE/Margin.app" "$OUT/Margin-mac-$BUILD.dmg"
print "Version $VERSION (build $BUILD)"
ls -la "$OUT" | awk '/Margin-mac/ {print $5, $9}'
