#!/usr/bin/env bash
#
# Screenshot the app, unattended, against the fictional demo data.
#
#   ./tools/screenshot.sh [out.png]
#
# Getting here took four dead ends, recorded so nobody repeats them:
#
#   cacheDisplay()            draws the view tree but cannot composite
#                             vibrancy or SwiftUI layers — sidebar came back blank
#   ScreenCaptureKit          needs Screen Recording permission, which an
#                             ad-hoc-signed binary run from a terminal is never asked for
#   screencapture -l <window> needs window-list access the caller lacks
#   screencapture -R <rect>   refuses every rect in this environment
#
# What does work is a full-screen grab, so the app reports where its window is
# and we crop to that ourselves. The window is also told it may join all
# Spaces — without that it lands on a Space a fullscreen app has taken over,
# and every capture catches that app instead.

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/docs/img/screenshot.png}"
APP="$REPO/Runbranch.app/Contents/MacOS/RunBranch"
BIN="$REPO/build/bin"

[ -x "$APP" ] || { echo "build the app first: ./make-app.sh" >&2; exit 1; }
[ -d "$REPO/demo" ] || "$REPO/tools/make-demo.sh" >/dev/null

if [ ! -x "$BIN/crop" ] || [ "$REPO/tools/crop.swift" -nt "$BIN/crop" ]; then
  mkdir -p "$BIN"; swiftc -O "$REPO/tools/crop.swift" -o "$BIN/crop"
fi

LOG="$(mktemp)"; FULL="$(mktemp -t rbfull).png"
export RB_PROJECTS_DIR="$REPO/demo/projects" RB_HOME="$REPO/demo/state" \
       RB_MY_EMAILS="dana@example.com"

"$APP" --hold 18 2>"$LOG" & APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true; rm -f "$LOG" "$FULL"' EXIT

for _ in $(seq 1 40); do grep -q '^RECT' "$LOG" && break; sleep 0.25; done
RECT="$(grep -m1 '^RECT' "$LOG" | awk '{print $2}')"
[ -n "$RECT" ] || { echo "the app never reported a window rect" >&2; exit 1; }

sleep 2                                  # health poll and the glass settling
screencapture -x -o "$FULL"

# The capture is in pixels and the rect in points, so scale between them —
# taken from the app, which knows its own screen, rather than parsed out of
# system_profiler.
SCALE="$(grep -m1 '^SCALE' "$LOG" | awk '{print $2}')"
[ -n "$SCALE" ] || SCALE=1

# A black frame means the display is asleep or locked; capture returns nothing
# and every crop of it is black. Worth saying so rather than writing the file.
BYTES=$(stat -f%z "$FULL")
if [ "$BYTES" -lt 200000 ]; then
  echo "the screen capture came back empty ($BYTES bytes) — the display is" >&2
  echo "asleep or locked. Wake it and run this again." >&2
  exit 1
fi

IFS=, read -r X Y W H <<<"$RECT"
"$BIN/crop" "$FULL" "$OUT" "$X" "$Y" "$W" "$H" "${SCALE:-1}"
echo "wrote $OUT"
