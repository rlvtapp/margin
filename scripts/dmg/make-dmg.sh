#!/bin/zsh
# Puts a built Margin.app in a disk image that opens as a laid-out window: the app and a shortcut
# to Applications, big icons over the picture in scripts/dmg (render it again with
# scripts/dmg/render-background.sh), and Margin's icon on the disk itself. Used by
# scripts/build-share.sh and scripts/release-mac.sh.
#   scripts/dmg/make-dmg.sh path/to/Margin.app path/to/out.dmg
set -euo pipefail
ROOT=${0:A:h:h:h}
APP=${1:?Pass the Margin.app to put in the disk image}
DMG=${2:?Pass where the disk image goes}
IMAGE=$(mktemp -d)
trap 'rm -rf $IMAGE' EXIT
ditto "$APP" "$IMAGE/Margin.app"
ln -s /Applications "$IMAGE/Applications"

# The disk image: made writable first, so Finder can lay out its window, then compressed.
mkdir "$IMAGE/.background"
cp "$ROOT/scripts/dmg/background.tiff" "$IMAGE/.background/background.tiff"
cp "$IMAGE/Margin.app/Contents/Resources/AppIcon.icns" "$IMAGE/.VolumeIcon.icns"
# Finder finds the disk by its name, so an older Margin disk image still open would get the
# layout instead. Ones made in .build are put away; anything else named Margin stops the build.
hdiutil info | awk '/^image-path/ {path = substr($0, index($0, ":") + 2)} /\/Volumes\/Margin$/ {print path}' | while read -r old; do
  if [[ $old == $ROOT/.build/* ]]; then
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
hdiutil convert "$WRITABLE/Margin.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
