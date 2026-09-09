#!/usr/bin/env bash
#
# A smoke test for the app, not the engine.
#
#   ./tests/ui.sh
#
# It launches the real app against the fictional demo data and asks it what it
# managed to do. That is a narrow thing to test, and it is narrow on purpose:
# the two bugs that came closest to shipping were both in this layer, and both
# were found by accident.
#
#   - Applying the saved presentation at launch called through to openWindow, so
#     every start opened a duplicate window. This test catches that: it counts
#     them, and a duplicate is invisible until something does.
#   - The run strip held the health monitor as a plain property rather than an
#     @ObservedObject, so it never subscribed to changes and a healthy run read
#     "Starting" indefinitely. This test now catches that too, but only by
#     reading the screen: every other assertion here asks the app what it
#     thinks, and in that bug the app thought correctly and drew something
#     else. The monitor was right the whole time.
#
# So the last two checks are different in kind from the rest. The app captures
# its own window through ScreenCaptureKit and runs Vision text recognition over
# it, and reports what came back. Asserting that the strip reads "healthy" and
# does not read "starting" is a claim about pixels, which is the only claim that
# would have failed on the original bug.
#
# An in-process accessibility walk was tried first and returns nothing, because
# SwiftUI does not build that tree unless an assistive client asks; System
# Events cannot see the window either.
#
# The screen read needs the Screen Recording grant, which is tied to the code
# signature and so absent on a machine that has never granted this build. When
# it is missing those two checks SKIP rather than fail — and say so loudly at
# the end, because a suite that counts "could not look" as "looks right" is
# worse than one that admits it did not look. Run tools/make-signing-identity.sh
# and grant it once; the grant then survives rebuilds.
#
# Does not take focus (RB_SHOT_QUIET), so it can be run while working.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/Runbranch.app"
VERBOSE="${1:-}"

[ -d "$APP" ] || { echo "build the app first: ./make-app.sh" >&2; exit 1; }
[ -d "$REPO/demo" ] || "$REPO/tools/make-demo.sh" >/dev/null

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); [ "$VERBOSE" = -v ] && printf '  ok    %s\n' "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP  %s\n' "$1"; return 0; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$3] not in what was drawn";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "[$3] IS in what was drawn";; *) ok "$1";; esac; }

OUT="$(mktemp)"
trap 'rm -f "$OUT"; env RB_PROJECTS_DIR="$REPO/demo/projects" RB_HOME="$REPO/demo/state" \
  "$REPO/runbranch.sh" stop northwind-web >/dev/null 2>&1' EXIT

# macOS ships no timeout(1).
limited() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

report() {  # sets REPORT to the app's own account of itself
  : > "$OUT"
  pkill -f 'Runbranch.app/Contents/MacOS/RunBranch' 2>/dev/null
  /bin/sleep 1
  # -g so the launch itself does not foreground the app: `open`
  # does that on its own, and the in-app activation guard cannot
  # stop it.
  limited 60 open -g -n -W \
    --env "RB_PROJECTS_DIR=$REPO/demo/projects" \
    --env "RB_HOME=$REPO/demo/state" \
    --env "RB_MY_EMAILS=dana@example.com" \
    --env "RB_NO_OPEN=1" \
    --env "RB_SHOT_QUIET=1" \
    --env "RB_SELFTEST_OUT=$OUT" \
    "$APP" --args --selftest >/dev/null 2>&1
  pkill -f 'Runbranch.app/Contents/MacOS/RunBranch' 2>/dev/null
  REPORT="$(cat "$OUT" 2>/dev/null)"
}

field() { printf '%s\n' "$REPORT" | awk -F'\t' -v k="$1" '$1==k {print $2}'; }

echo "==> the app launches and settles"
report
[ -n "$REPORT" ] || { echo "  FAIL  the app produced no report at all"; exit 1; }
# Exactly one. A duplicate window at launch is invisible until you count them.
is "exactly one window"        "$(field windows)"  "1"
is "the projects loaded"       "$(field projects)" "4"
is "something is selected"     "$([ -n "$(field selected)" ] && echo yes || echo no)" "yes"
is "and nothing went wrong"    "$(field problem)"  ""

echo "==> a running project reports healthy, not starting"
env RB_PROJECTS_DIR="$REPO/demo/projects" RB_HOME="$REPO/demo/state" RB_NO_OPEN=1 \
  "$REPO/runbranch.sh" run northwind-web feat/checkout-summary web >/dev/null 2>&1
for _ in $(seq 1 30); do curl -sfo /dev/null http://localhost:4173/ && break; /bin/sleep 1; done
report
is "the run is seen"           "$(field running)" "1"
is "with its target"           "$(field targets)" "1"
# The bug this exists for: the strip kept whatever it drew first, so a healthy
# run read "starting" forever.
is "health actually resolves"  "$(field health)"  "healthy"
is "still exactly one window"  "$(field windows)" "1"

# And the same claim again, about the pixels rather than the state. This is the
# pair that would have failed on the stale-render bug; everything above passed
# through it.
echo "==> and the strip has drawn it"
DRAWN="$(field drawn)"
if [ "$(field drawnok)" != 1 ]; then
  skip "the window could not be read: $(field drawnwhy)"
  skip "so what it drew was not checked — see this file's header"
else
  hasnt "the strip does not still say starting" "$DRAWN" "starting"
  has   "the strip says healthy"                "$DRAWN" "healthy"
fi

printf '\n%d passed, %d failed' "$PASS" "$FAIL"
[ "$SKIP" = 0 ] && printf '\n' || printf ', %d SKIPPED — the render was not checked\n' "$SKIP"
[ "$FAIL" = 0 ]
