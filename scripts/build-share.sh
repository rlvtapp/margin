#!/bin/zsh
# Makes a Mac build to hand to someone: .build/share/Margin-mac.dmg (the app with a shortcut to
# Applications beside it, to drag it in) and Margin-mac.zip. It's signed ad hoc, not notarized,
# so the first time they right-click the app and choose Open.
set -euo pipefail
ROOT=${0:A:h:h}
OUT=$ROOT/.build/share
DATA=$ROOT/.build/xcode-share
IMAGE=$(mktemp -d)
trap 'rm -rf $IMAGE' EXIT

xcodebuild -project $ROOT/Apps/Margin.xcodeproj -scheme "Margin (Release)" -destination 'platform=macOS' -derivedDataPath $DATA \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

ditto $DATA/Build/Products/Release/Margin.app $IMAGE/Margin.app
codesign --verify --deep --strict $IMAGE/Margin.app
ln -s /Applications $IMAGE/Applications

mkdir -p $OUT
rm -f $OUT/Margin-mac.dmg $OUT/Margin-mac.zip
hdiutil create -volname Margin -srcfolder $IMAGE -format ULMO -ov $OUT/Margin-mac.dmg >/dev/null
(cd $IMAGE && ditto -c -k --sequesterRsrc --keepParent Margin.app $OUT/Margin-mac.zip)
ls -la $OUT | awk '/Margin-mac/ {print $5, $9}'
