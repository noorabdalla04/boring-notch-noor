#!/usr/bin/env bash
# Build this fork of Boring Notch and install it next to (not over) the official app.
#
#   scripts/build-and-install.sh
#
# Installs to "$APP_DEST" (default "/Applications/Boring Notch (Custom).app"), quits
# the running copy, moves the previous build to the Trash, and launches the new one.
# The bundle id is theboringteam.boringnotch.noor, so settings and permissions are
# separate from the official Boring Notch, and its update feed points nowhere, so an
# official update can never replace this build.
#
# Signing. With no configuration the app is signed ad hoc. That works, but macOS
# then treats every rebuild as a new app and asks for Calendar/Reminders access
# again. To keep permissions across rebuilds, sign with a stable identity: create a
# code-signing certificate (Keychain Access > Certificate Assistant > Create a
# Certificate, type "Code Signing") and point this script at it in
# ~/.config/boring-notch/signing.env:
#
#   SIGN_IDENTITY="My Local Code Signing"
#   SIGN_KEYCHAIN="$HOME/Library/Keychains/my-signing.keychain-db"          # optional
#   SIGN_KEYCHAIN_PASSWORD_FILE="$HOME/.config/boring-notch/keychain-pass"  # optional
#   APP_DEST="/Applications/Boring Notch (Custom).app"                      # optional
#
# The hardened runtime is off: an ad-hoc-built app with it on refuses to load its
# own embedded frameworks ("different Team IDs"). The App Sandbox stays on.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="$HOME/.config/boring-notch/signing.env"
[ -f "$CONFIG" ] && source "$CONFIG"
APP_DEST="${APP_DEST:-/Applications/Boring Notch (Custom).app}"
DERIVED="${DERIVED:-$PWD/build}"
APP_BUILT="$DERIVED/Build/Products/Release/Boring Notch.app"
BUNDLE_ID="theboringteam.boringnotch.noor"

mkdir -p "$DERIVED"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=NO ONLY_ACTIVE_ARCH=YES \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u | tee "$DERIVED/last-build.txt"
grep -q "BUILD SUCCEEDED" "$DERIVED/last-build.txt" || exit 1

if [ -n "${SIGN_IDENTITY:-}" ]; then
  KEYCHAIN_ARGS=()
  if [ -n "${SIGN_KEYCHAIN:-}" ]; then
    if [ -n "${SIGN_KEYCHAIN_PASSWORD_FILE:-}" ]; then
      security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$SIGN_KEYCHAIN"
    fi
    KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
  fi
  sign() { codesign --force "${KEYCHAIN_ARGS[@]}" --sign "$SIGN_IDENTITY" --preserve-metadata=identifier,entitlements,flags "$@"; }
  for fw in "$APP_BUILT"/Contents/Frameworks/*.framework; do sign --deep "$fw"; done
  for xpc in "$APP_BUILT"/Contents/XPCServices/*.xpc; do sign "$xpc"; done
  sign "$APP_BUILT"
  codesign --verify --deep --strict "$APP_BUILT"
else
  echo "Signed ad hoc (no SIGN_IDENTITY in $CONFIG): macOS will ask for Calendar access again after each rebuild."
fi

osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
# It doesn't always honour Quit (e.g. while the screen is locked); then force only
# this install's own process, never the official Boring Notch.
own_pids() { ps -axo pid=,command= | grep -F "$APP_DEST/Contents/MacOS/" | grep -v grep | awk '{print $1}'; }
for _ in 1 2 3 4 5; do [ -z "$(own_pids)" ] && break; sleep 1; done
for pid in $(own_pids); do kill -9 "$pid" 2>/dev/null || true; done
sleep 1
if [ -e "$APP_DEST" ]; then
  mv "$APP_DEST" "$HOME/.Trash/$(basename "$APP_DEST" .app) $(date +%Y%m%d-%H%M%S).app"
fi
ditto "$APP_BUILT" "$APP_DEST"
# Keep exactly one copy of the app on the Mac: drop the build-folder copy once installed.
rm -rf "$APP_BUILT"
open "$APP_DEST"
echo "Installed and launched: $APP_DEST"
