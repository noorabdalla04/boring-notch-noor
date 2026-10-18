#!/usr/bin/env bash
# NoorLab: work on the notch UI in a sandbox, never on the real notch or screen.
#
#   scripts/lab.sh build            build a lab copy (build-lab/, signed like the real app)
#   scripts/lab.sh start            run it: an invisible window behind the desktop picture
#   scripts/lab.sh cmd "drag 320 181 320 260" "state" ...   drive it (see NoorLab.swift)
#   scripts/lab.sh snap NAME        capture the lab window to lab-shots/NAME.png
#   scripts/lab.sh stop
#
# Extra launch arguments go in LAB_ARGS, e.g. LAB_ARGS="-NoorLabFreshPrayer YES" to
# start without a prayer location. Writes (Reminders) are simulated unless LAB_ARGS
# includes "-NoorLabLive YES". The lab copy is unregistered from Launch Services and
# never indexed, so the only Boring Notch on the Mac stays the installed one.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="$PWD/build-lab"
APP="$DERIVED/Build/Products/Release/Boring Notch.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LABDIR="$HOME/Library/Containers/theboringteam.boringnotch.noor/Data/tmp/noor-lab"

case "${1:-}" in
build)
  mkdir -p "$DERIVED"; touch "$DERIVED/.metadata_never_index"
  xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
    -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    ENABLE_HARDENED_RUNTIME=NO ONLY_ACTIVE_ARCH=YES build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u | tee "$DERIVED/last-build.txt"
  grep -q "BUILD SUCCEEDED" "$DERIVED/last-build.txt" || exit 1
  # Same signing as the installed app (see build-and-install.sh), so the lab copy
  # already has Calendar/Reminders access.
  CONFIG="$HOME/.config/boring-notch/signing.env"
  [ -f "$CONFIG" ] && source "$CONFIG"
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    KEYCHAIN_ARGS=()
    if [ -n "${SIGN_KEYCHAIN:-}" ]; then
      if [ -n "${SIGN_KEYCHAIN_PASSWORD_FILE:-}" ]; then
        security unlock-keychain -p "$(cat "$SIGN_KEYCHAIN_PASSWORD_FILE")" "$SIGN_KEYCHAIN"
      fi
      KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
    fi
    sign() { codesign --force "${KEYCHAIN_ARGS[@]}" --sign "$SIGN_IDENTITY" --preserve-metadata=identifier,entitlements,flags "$@" 2>/dev/null; }
    for fw in "$APP"/Contents/Frameworks/*.framework; do sign --deep "$fw"; done
    for xpc in "$APP"/Contents/XPCServices/*.xpc; do sign "$xpc"; done
    sign "$APP"
  fi
  "$LSREG" -u "$APP" 2>/dev/null || true
  [ -x "$DERIVED/labctl" ] && [ "$DERIVED/labctl" -nt tools/labctl.swift ] || swiftc -O tools/labctl.swift -o "$DERIVED/labctl"
  ;;
start)
  "$0" stop >/dev/null 2>&1 || true
  rm -f "$LABDIR/lab.log" "$LABDIR/window-id"
  nohup "$APP/Contents/MacOS/Boring Notch" -NoorLab YES -menubarIcon NO ${LAB_ARGS:-} >/dev/null 2>&1 &
  for _ in $(seq 1 60); do grep -q '^ready' "$LABDIR/lab.log" 2>/dev/null && break; sleep 0.25; done
  sleep 1.5; head -1 "$LABDIR/lab.log"
  ;;
cmd)
  shift; "$DERIVED/labctl" "$@"
  ;;
snap)
  mkdir -p lab-shots
  screencapture -x -o -l "$(cat "$LABDIR/window-id")" "lab-shots/$2.png" && echo "lab-shots/$2.png"
  ;;
stop)
  # The app ignores SIGTERM; ask it to quit, then force only the lab copies.
  [ -x "$DERIVED/labctl" ] && timeout 3 "$DERIVED/labctl" quit >/dev/null 2>&1 || true
  sleep 0.5
  pkill -9 -f -- "-NoorLab YES" || true
  ;;
*) sed -n '2,13p' "$0"; exit 1 ;;
esac
