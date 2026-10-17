#!/usr/bin/env bash
# Build and install Noor's customised Boring Notch side by side with the official app.
#
#   ./noor-build.sh            build + install to "/Applications/Boring Notch (Noor).app"
#
# Customisations on this branch (noor-custom, based on tag v2.8-rc.2):
#   - FlowSavvy / FlowLocal task blocks get a checkbox in the notch calendar
#     (boringNotch/extensions/TaskBlocks.swift; Settings -> Calendar -> Task blocks)
#   - Open notch home: swipeable Calendar · Prayers · Pomodoro pager
#     (extensions/HomeWidgets.swift, PrayerTimes.swift, Pomodoro.swift); a running
#     Pomodoro shows its time left in the closed notch
#   - Bundle id theboringteam.boringnotch.noor, so it runs beside the official app
#   - Update feed points nowhere, so an official update can never replace this build
#
# Signing: built ad-hoc ("-"), then re-signed with the local "Noor Local Code Signing"
# identity (its own keychain, ~/Library/Keychains/boringnotch-noor-signing.keychain-db)
# so permissions persist across rebuilds. The hardened
# runtime is off because an ad-hoc app with it on refuses to load its own embedded
# frameworks (MediaRemoteAdapter) -- "different Team IDs". The App Sandbox stays on.
set -euo pipefail
cd "$(dirname "$0")"

DERIVED="$PWD/build"
APP_BUILT="$DERIVED/Build/Products/Release/Boring Notch.app"
APP_DEST="/Applications/Boring Notch (Noor).app"
BUNDLE_ID="theboringteam.boringnotch.noor"

xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=NO ONLY_ACTIVE_ARCH=YES \
  build | tail -n 3

# Re-sign with a stable local identity so macOS recognises every build as the SAME app:
# privacy permissions (Calendar, Reminders) granted once stay granted across rebuilds.
# Ad-hoc signatures change every build, which made macOS ask again each time.
KC="$HOME/Library/Keychains/boringnotch-noor-signing.keychain-db"
SIGN_ID="Noor Local Code Signing"
security unlock-keychain -p "$(cat "$HOME/.config/boringnotch-noor/keychain-pass")" "$KC"
sign() { codesign --force --keychain "$KC" --sign "$SIGN_ID" --preserve-metadata=identifier,entitlements,flags "$@"; }
for fw in "$APP_BUILT"/Contents/Frameworks/*.framework; do sign --deep "$fw"; done
for xpc in "$APP_BUILT"/Contents/XPCServices/*.xpc; do sign "$xpc"; done
sign "$APP_BUILT"
codesign --verify --deep --strict "$APP_BUILT"

osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
sleep 2
if [ -e "$APP_DEST" ]; then
  mv "$APP_DEST" "$HOME/.Trash/Boring Notch (Noor) $(date +%Y%m%d-%H%M%S).app"
fi
ditto "$APP_BUILT" "$APP_DEST"
# Keep exactly one Boring Notch on the Mac: drop the build-folder copy once installed.
rm -rf "$APP_BUILT"
open "$APP_DEST"
echo "Installed and launched: $APP_DEST"
