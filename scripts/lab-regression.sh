#!/usr/bin/env bash
# End-to-end checks of the notch widgets in the NoorLab sandbox (scripts/lab.sh).
# Never touches the real notch; Reminders writes are simulated.
#
#   scripts/lab-regression.sh          (build the lab first: scripts/lab.sh build)
set -uo pipefail
cd "$(dirname "$0")/.."
LAB=scripts/lab.sh
pass=0; fail=0

check() {  # check "name" "haystack" "needle"
  if grep -qF -- "$3" <<<"$2"; then pass=$((pass + 1)); echo "  ok    $1"
  else fail=$((fail + 1)); echo "  FAIL  $1"; echo "        wanted: $3"; echo "        got:    $2"; fi
}
state() { $LAB cmd "$@" state | grep '^state' | tail -1; }

echo "Pull-down"
$LAB start >/dev/null
s=$(state "wait 300");                                        check "opens folded"            "$s" '"expanded":false'
check "window is normal height" "$s" '"windowHeight":210'
s=$(state "drag 320 181 320 240" "wait 700");                 check "drag 59 pt expands"      "$s" '"expanded":true'
check "window grew"             "$s" '"windowHeight":450'
s=$(state "drag 320 422 320 330" "wait 1200");                check "drag up folds"           "$s" '"expanded":false'
check "window shrank back"      "$s" '"windowHeight":210'
s=$(state "drag 320 181 320 201 10" "wait 1200");             check "short drag springs back" "$s" '"expanded":false'
s=$(state "click 320 181" "wait 600");                        check "click expands"           "$s" '"expanded":true'
s=$(state "click 320 422" "wait 1200");                       check "click folds"             "$s" '"expanded":false'
s=$(state "scroll 150 100 140" "wait 700");                   check "scroll down expands"     "$s" '"expanded":true'
s=$(state "scroll 150 100 -140" "wait 1200");                 check "scroll up folds"         "$s" '"expanded":false'
s=$(state "expand" "wait 400" "close" "wait 600");            check "close folds and closes"  "$s" '"notch":"closed"'
s=$(state "open" "wait 900");                                 check "reopens folded"          "$s" '"expanded":false'

echo "Pages"
for p in 1 2 3 0; do s=$(state "page $p" "wait 400"); check "page $p" "$s" "\"page\":$p"; done

echo "Reminders (simulated)"
r=$($LAB cmd "page 1" "wait 1500" reminders | grep '^reminders' | tail -1)
check "reminders load"          "$r" '"total":'
before=$(sed -E 's/.*"total":([0-9]+).*/\1/' <<<"$r")
r=$($LAB cmd "tick 0" "wait 300" reminders | grep '^reminders' | tail -1)
check "tick shows pending"      "$r" '"pending":1'
r=$($LAB cmd "wait 1800" reminders | grep '^reminders' | tail -1)
check "tick completes"          "$r" "\"total\":$((before - 1))"
r=$($LAB cmd "click 597 57" "wait 400" "type Lab regression item" "key return" "wait 600" "key escape" reminders | grep '^reminders' | tail -1)
check "typed reminder is added" "$r" "\"total\":$before"
$LAB stop >/dev/null

echo "Prayer times"
$LAB start >/dev/null
p=$($LAB cmd "page 2" "wait 1500" prayers | grep '^prayers' | tail -1)
calendar_line="$p"
check "times from the calendar" "$p" 'source=calendar'
check "six times today"         "$p" 'Isha'
$LAB stop >/dev/null
LAB_ARGS="-prayerSource calculated -NoorLabFreshPrayer YES" $LAB start >/dev/null
p=$($LAB cmd "page 2" "wait 1200" prayers | grep '^prayers' | tail -1)
check "new user is asked"       "$p" 'needsLocation=true'
p=$($LAB cmd "prayer-search Ottawa" "wait 3500" "prayer-pick 0" "wait 3500" prayers | grep '^prayers' | tail -1)
check "calculated after pick"   "$p" 'needsLocation=false failed=false'
for name in Fajr Dhuhr Maghrib Isha; do
  want=$(grep -oE "$name [0-9]{2}:[0-9]{2}" <<<"$calendar_line" | head -1)
  [ -n "$want" ] && check "$name matches the calendar" "$p" "$want"
done
if grep -q " iq " <<<"$p"; then fail=$((fail + 1)); echo "  FAIL  new user got iqama times"
else pass=$((pass + 1)); echo "  ok    no iqama merged for a new user"; fi
$LAB stop >/dev/null

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
