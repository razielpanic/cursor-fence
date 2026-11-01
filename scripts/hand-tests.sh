#!/bin/zsh
# Voice-cued hand tests on the hardware path, which synthetic events cannot
# reach. A person flicks the real mouse while FenceHarness records the
# fenced display; then the app is killed and quit while the pointer is held
# against the wall, and the person checks the mouse still moves.
#
# Run with Cursor Fence already running and fencing a display.
set -uo pipefail
cd "$(dirname "$0")/.."
H="$(swift build -c release --show-bin-path)/FenceHarness"
APP=build/CursorFence.app
ID=com.razielpanic.CursorFence
OUT=test-results
STATS="$HOME/Library/Application Support/CursorFence/stats.json"
SECONDS_PER_RUN=${SECONDS_PER_RUN:-20}
mkdir -p $OUT

relaunch() {
  osascript -e "quit app id \"$ID\"" >/dev/null 2>&1
  sleep 1.5
  open $APP
  sleep 3
}
disassociated() { /usr/bin/grep -q '"disassociated" : true' "$STATS" && echo yes || echo no; }

say "Cursor Fence hand tests start in ten seconds. Put your hand on the mouse, with the pointer on the work screen."
sleep 8
say "Hand test one. Normal mode. In three seconds, flick the mouse hard at the fenced display, again and again, until I say stop."
sleep 3
say -r 260 "go" &
$H leak --drive manual --seconds $SECONDS_PER_RUN --out $OUT/hand-disassociate > $OUT/hand-disassociate.json
say "Stop."

defaults write $ID mechanism rewriteOnly
relaunch
say "Hand test two. Rewrite only mode, for comparison. Flick again in three seconds."
sleep 3
say -r 260 "go" &
$H leak --drive manual --seconds $SECONDS_PER_RUN --out $OUT/hand-rewrite > $OUT/hand-rewrite.json
say "Stop."
defaults write $ID mechanism disassociate
relaunch

say "Failsafe test. Push the pointer against the wall and keep pushing. I will kill the app in five seconds."
sleep 5
before=$(disassociated)
pkill -9 -f "$APP/Contents/MacOS/CursorFence$"
sleep 0.5
say "Killed. Move the mouse away from the wall. Remember whether it moved."
echo "kill -9: disassociated before kill = $before; guardian alive after = $(pgrep -f -- '--guardian' >/dev/null && echo yes || echo no)" > $OUT/failsafe.txt
sleep 6
open $APP
sleep 3

say "Next. Push the pointer against the wall again. I will quit the app in five seconds."
sleep 5
before=$(disassociated)
osascript -e "quit app id \"$ID\""
sleep 0.5
say "Quit. Move the mouse away from the wall. Remember whether it moved."
echo "quit: disassociated before quit = $before" >> $OUT/failsafe.txt
sleep 6
open $APP
say "Hand tests done. Tell Claude whether the mouse moved both times."
