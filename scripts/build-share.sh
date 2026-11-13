#!/bin/zsh
# Makes a Mac build to hand to someone: .build/share/Margin-mac-<build>.dmg (the app with a
# shortcut to Applications beside it, to drag it in) and Margin-mac-<build>.zip. It's signed ad hoc, not notarized,
# so the first time they right-click the app and choose Open.
# The disk image opens as a laid-out window: big icons over the picture in scripts/dmg (render
# it again with scripts/dmg/render-background.sh), and Margin's icon on the disk itself.
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
typeset -a version_settings
version_settings=("CURRENT_PROJECT_VERSION=$BUILD")

# A failed compile must never package the previous app left in DerivedData.
if ! xcodebuild -project "$ROOT/Apps/Margin.xcodeproj" -scheme "Margin (Release)" -destination 'platform=macOS' -derivedDataPath "$DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  "${version_settings[@]}" build > "$OUT/build.log" 2>&1; then
  tail -n 80 "$OUT/build.log"
  exit 1
fi
print "BUILD SUCCEEDED"

ditto "$DATA/Build/Products/Release/Margin.app" "$IMAGE/Margin.app"
codesign --verify --deep --strict "$IMAGE/Margin.app"
ln -s /Applications "$IMAGE/Applications"

mkdir -p "$OUT"
# Only the newest build stays, so an old file is never sent by mistake.
rm -f "$OUT"/Margin-mac*.dmg(N) "$OUT"/Margin-mac*.zip(N)
(cd "$IMAGE" && ditto -c -k --sequesterRsrc --keepParent Margin.app "$OUT/Margin-mac-$BUILD.zip")

# The disk image: made writable first, so Finder can lay out its window, then compressed.
mkdir "$IMAGE/.background"
cp "$ROOT/scripts/dmg/background.tiff" "$IMAGE/.background/background.tiff"
cp "$IMAGE/Margin.app/Contents/Resources/AppIcon.icns" "$IMAGE/.VolumeIcon.icns"
# Finder finds the disk by its name, so an older Margin disk image still open would get the
# layout instead. Ones made here are put away; anything else named Margin stops the build.
hdiutil info | awk '/^image-path/ {path = substr($0, index($0, ":") + 2)} /\/Volumes\/Margin$/ {print path}' | while read -r old; do
  if [[ $old == $ROOT/.build/share/* ]]; then
    hdiutil detach /Volumes/Margin -quiet || hdiutil detach /Volumes/Margin -force -quiet
  fi
done
if [[ -e /Volumes/Margin ]]; then
  print "A disk named Margin is open (/Volumes/Margin). Eject it and run this again."
  exit 1
fi
WRITABLE=$(mktemp -d)
MOUNT=$(mktemp -d)
trap 'hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; rm -rf $IMAGE $WRITABLE $MOUNT' EXIT
hdiutil create -volname Margin -srcfolder "$IMAGE" -fs HFS+ -format UDRW -ov "$WRITABLE/Margin.dmg" >/dev/null 2>&1
hdiutil attach "$WRITABLE/Margin.dmg" -readwrite -noverify -noautoopen -mountpoint "$MOUNT" >/dev/null 2>&1
# The disk shows Margin's icon.
SetFile -a C "$MOUNT" 2>/dev/null || true
# The window: 720 × 420 without a toolbar, icons 160 points, the app on the left and Applications
# on the right, where the picture's arrow points. Where Finder can't be asked (no permission, no
# one signed in), the disk image still works, just without the layout.
LAYOUT="
tell application \"Finder\"
  set theDisk to (POSIX file \"$MOUNT\" as alias)
  open theDisk
  delay 1
  set theWindow to container window of theDisk
  set current view of theWindow to icon view
  set toolbar visible of theWindow to false
  set statusbar visible of theWindow to false
  -- The path bar (View → Show Path Bar) would cover the bottom of the picture.
  try
    set pathbar visible of theWindow to false
  end try
  set bounds of theWindow to {200, 120, 920, 568}
  set theOptions to icon view options of theWindow
  set arrangement of theOptions to not arranged
  set icon size of theOptions to 160
  set text size of theOptions to 14
  set label position of theOptions to bottom
  set shows item info of theOptions to false
  set background picture of theOptions to file \".background:background.tiff\" of theDisk
  set position of item \"Margin.app\" of theDisk to {190, 215}
  set position of item \"Applications\" of theDisk to {530, 215}
  update theDisk without registering applications
  delay 2
  close theWindow
end tell"
if ! FINDER_ERROR=$(osascript -e "$LAYOUT" 2>&1); then print "Finder couldn't lay out the disk image's window ($FINDER_ERROR); it opens as a plain folder."; fi
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
# Finder can hold on to the disk for a moment after its window closes.
for attempt in 1 2 3 4 5; do
  hdiutil detach "$MOUNT" -quiet 2>/dev/null && break
  sleep 2
  [[ $attempt == 5 ]] && hdiutil detach "$MOUNT" -force -quiet
done
hdiutil convert "$WRITABLE/Margin.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT/Margin-mac-$BUILD.dmg" >/dev/null
print "Build $BUILD"
ls -la "$OUT" | awk '/Margin-mac/ {print $5, $9}'
