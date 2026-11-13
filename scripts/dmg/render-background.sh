#!/bin/zsh
# Renders background.html into background.tiff (720 × 420, with a sharp copy for Retina screens
# inside), the picture behind the disk image's window. Needs Google Chrome.
set -euo pipefail
HERE=${0:A:h}
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT

for scale in 1 2; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=$scale \
    --window-size=720,420 --screenshot="$WORK/background-$scale.png" "file://$HERE/background.html" >/dev/null 2>&1
done
# Finder picks the copy that suits the screen.
tiffutil -cathidpicheck "$WORK/background-1.png" "$WORK/background-2.png" -out "$HERE/background.tiff" >/dev/null
print "$HERE/background.tiff"
