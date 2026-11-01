#!/bin/zsh
# Voice-cued corner test: a person pushes the real mouse into the fenced
# corner, without clicking, while this script puts a different app in front
# for each window. Then it dumps the trace and scores each window with
# scripts/trace-windows.py.
#
#   scripts/corner-windows.sh [app ...]      default: CursorFence Finder CursorFence Claude Finder CursorFence
#
# Run with Cursor Fence already running and fencing a display.
set -uo pipefail
cd "$(dirname "$0")/.."
DIR="$HOME/Library/Application Support/CursorFence"
OUT=test-results
SECS=${SECS:-15}
apps=("$@")
(( ${#apps} )) || apps=(CursorFence Finder CursorFence Claude Finder CursorFence)
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p $OUT

say "Corner test. ${#apps} windows of $SECS seconds. Don't click; I'll switch apps for you. Put the pointer on the laptop screen."
sleep 2
n=0
for app in $apps; do
  n=$((n + 1))
  osascript -e "tell application \"$app\" to activate" >/dev/null
  sleep 1
  say "Window $n, $app in front. Push into the corner. Go."
  sleep $SECS
  say "Stop."
  sleep 1
done

rm -f "$DIR/trace.csv"
touch "$DIR/dump-trace"
for _ in {1..20}; do [[ -f "$DIR/trace.csv" ]] && break; sleep 0.25; done
cp "$DIR/trace.csv" $OUT/corner-$stamp.csv
cp "$DIR/stats.json" $OUT/corner-$stamp-stats.json
say "Done."
python3 -I scripts/trace-windows.py $OUT/corner-$stamp.csv
