#!/bin/zsh
# Builds the Mac app signed with your development certificate and puts it in /Applications,
# replacing the one there, then opens it. The version is the day (2026.11.19) and the build
# number the date and time (20261112.1742). Needs your team id:
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/install-mac.sh
set -euo pipefail
ROOT=${0:A:h:h}
DATA=${MARGIN_INSTALL_DATA:-$ROOT/.build/xcode-install}
BUILD=${MARGIN_BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}
# The version is the day: 2026.11.19 (docs/release.md).
VERSION=${MARGIN_VERSION:-$(date +%Y.%-m.%-d)}
: ${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple developer team id}

if ! xcodebuild -project "$ROOT/Apps/Margin.xcodeproj" -scheme "Margin (Release)" -destination 'platform=macOS' -derivedDataPath "$DATA" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build > "$DATA.log" 2>&1; then
  tail -n 80 "$DATA.log"
  exit 1
fi
# Only the app: AI apps' bridges (`Margin --mcp`) and their cores are also called Margin, and
# killing them leaves Codex or Claude with a closed connection until they're restarted.
for pid in $(pgrep -x Margin || true); do
  ps -o args= -p $pid | grep -q -- '--mcp' || kill $pid 2>/dev/null || true
done
sleep 1
rm -rf /Applications/Margin.app
ditto "$DATA/Build/Products/Release/Margin.app" /Applications/Margin.app
open /Applications/Margin.app
print "Installed version $VERSION (build $BUILD)"
