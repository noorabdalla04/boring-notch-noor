#!/usr/bin/env bash
# Render the notch widget pages offscreen and copy the PNGs here (./snapshots).
# Works even when the notch's display is asleep or mirrored.
set -euo pipefail
cd "$(dirname "$0")"
SRC="$HOME/Library/Containers/theboringteam.boringnotch.noor/Data/tmp/noor-snapshots"
rm -f "$SRC"/*.png 2>/dev/null || true
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("noor.notch.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)'
for _ in $(seq 1 20); do [ -f "$SRC/expanded-pomodoro.png" ] && break; sleep 0.5; done
mkdir -p snapshots && cp "$SRC"/*.png snapshots/ && ls snapshots
