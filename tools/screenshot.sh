#!/usr/bin/env bash
#
# Screenshot every documented screen, unattended, against the fictional demo
# data. Nothing real appears in any of them.
#
#   ./tools/screenshot.sh            all scenes into docs/img/
#   ./tools/screenshot.sh main       just one
#   RB_SHOT_QUIET=1 ./tools/screenshot.sh   without taking focus
#
# A docs capture has to take focus: a window that is not frontmost photographs
# with grey traffic lights and dimmed controls. Checking a layout does not, and
# taking focus five times a run makes the machine unusable alongside — so set
# RB_SHOT_QUIET for that, and accept inactive-looking chrome.
#
# The app photographs its own window (see Screenshot in app/RunBranch.swift).
# It needs Screen Recording permission, which macOS will not prompt for on a
# binary launched from a terminal. Grant it by hand, once:
#   System Settings > Privacy & Security > Screen Recording > + > Runbranch.app
#
# That grant is keyed to the app's code signature. An ad-hoc signature changes
# with every build, so the grant would be dropped on every rebuild — run
# ./tools/make-signing-identity.sh first and the signature stays fixed, which
# means granting once is enough. Symptom if you skip it: every capture fails
# with "never became visible to the capture API", and the reported window list
# is short and owned only by system processes.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/Runbranch.app/Contents/MacOS/RunBranch"
OUT="$REPO/docs/img"

[ -x "$APP" ] || { echo "build the app first: ./make-app.sh" >&2; exit 1; }
[ -d "$REPO/demo" ] || "$REPO/tools/make-demo.sh" >/dev/null

# The running strip is only honest if something is actually running. A left-over
# state file from an earlier session shows "Starting" with a day of uptime,
# which is worse than showing nothing: it is a state the app cannot really be
# in. So start a real demo run, and stop it on the way out.
DEMO_ENV=(RB_PROJECTS_DIR="$REPO/demo/projects" RB_HOME="$REPO/demo/state" RB_NO_OPEN=1)
demo_down() {
  env "${DEMO_ENV[@]}" "$REPO/runbranch.sh" stop northwind-web >/dev/null 2>&1 || true
}
# Captures must not depend on how the app was last configured. A menu bar item
# is a window too, and it stretched one crop from 1140x860 to 2174x1720.
SAVED_PRESENTATION="$(defaults read dev.runbranch.app presentation 2>/dev/null || echo)"
defaults write dev.runbranch.app presentation dock
restore_presentation() {
  if [ -n "$SAVED_PRESENTATION" ]; then
    defaults write dev.runbranch.app presentation "$SAVED_PRESENTATION"
  else
    defaults delete dev.runbranch.app presentation 2>/dev/null || true
  fi
}

echo "==> starting the demo run so health and uptime are real"
demo_down
env "${DEMO_ENV[@]}" "$REPO/runbranch.sh" run northwind-web feat/checkout-summary web \
  >/dev/null 2>&1 || echo "  !! demo run failed; the running strip will be empty" >&2

# Wait for the port to actually answer. Capturing sooner catches the amber
# "Starting" state, which is accurate but not what the docs are illustrating.
for _ in $(seq 1 30); do
  curl -sfo /dev/null "http://localhost:4173/" && break
  /bin/sleep 1
done
curl -sfo /dev/null "http://localhost:4173/" \
  || echo "  !! port 4173 never answered; health will read as starting" >&2
trap 'demo_down; restore_presentation; rm -rf "$EMPTY"' EXIT

# Onboarding has to be shot against an empty config directory, since the
# welcome screen only appears when nothing is declared.
EMPTY="$(mktemp -d)"
mkdir -p "$EMPTY/projects" "$EMPTY/state"

# macOS ships no timeout(1), and a wedged capture must not wedge the pipeline.
run_limited() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

shoot() {  # file, scene, projects-dir, state-dir
  local file="$1" scene="$2" pdir="$3" sdir="$4"
  # A previous instance still holding a window makes the next capture fail.
  # Any surviving instance, not just a screenshot one. While one holds the
  # bundle, a newly launched instance starts but never creates a window and
  # reports nothing at all — no error, no log, just a process that sits there
  # until it is killed. The old pattern missed plain instances, so a single
  # stray one silently broke every capture that followed.
  pkill -f 'Runbranch.app/Contents/MacOS/RunBranch' 2>/dev/null
  # Long enough for the window server to actually let go. At 0.4s the first
  # capture after a rebuild failed while a retry of the same scene worked,
  # which is the signature of racing the previous instance rather than of
  # anything being wrong with the capture.
  /bin/sleep 1.5
  rm -f "$OUT/$file"
  # Launch through LaunchServices, not by exec'ing Contents/MacOS/RunBranch.
  # Exec'ing it proved unreliable: the process starts, never creates a window,
  # logs nothing at all, and sits there until it is killed. Through `open` it
  # works every time. A bundle wants to be launched as a bundle.
  #
  # -W waits for exit. --env is needed because a GUI launch does not inherit
  # this shell's environment. Diagnostics come back through RB_SHOT_LOG, since
  # the app's stderr is not connected to this terminal.
  local log="$OUT/.capture.log"
  : > "$log"
  run_limited 75 open ${RB_SHOT_QUIET:+-g} -n -W \
    --env "RB_PROJECTS_DIR=$pdir" \
    --env "RB_HOME=$sdir" \
    --env "RB_MY_EMAILS=dana@example.com" \
    --env "RB_SCAN_ROOT=/Users/you/Development" \
    --env "RB_NO_OPEN=1" \
    --env "RB_SHOT_LOG=$log" \
    ${RB_SHOT_QUIET:+--env "RB_SHOT_QUIET=$RB_SHOT_QUIET"} \
    "$REPO/Runbranch.app" --args --screenshot "$OUT/$file" --scene "$scene" \
    >/dev/null 2>&1
  [ -s "$log" ] && sed 's/^/    /' "$log"
  rm -f "$log"
  if [ -s "$OUT/$file" ]; then
    printf '  %-22s %s\n' "$file" "$(sips -g pixelWidth -g pixelHeight "$OUT/$file" \
      | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
  else
    printf '  %-22s FAILED\n' "$file"
    return 1
  fi
}

WANT="${1:-all}"
FAIL=0
echo "==> screenshots"
case "$WANT" in
  all|onboarding) shoot "onboarding.png" main "$EMPTY/projects" "$EMPTY/state" || FAIL=1 ;;
esac
case "$WANT" in
  all|main)     shoot "screenshot.png" main     "$REPO/demo/projects" "$REPO/demo/state" || FAIL=1 ;;
esac
case "$WANT" in
  all|settings) shoot "settings.png"   settings "$REPO/demo/projects" "$REPO/demo/state" || FAIL=1 ;;
esac
case "$WANT" in
  all|scan)     shoot "scan.png"       scan     "$REPO/demo/projects" "$REPO/demo/state" || FAIL=1 ;;
esac
case "$WANT" in
  all|about)    shoot "about.png"      about    "$REPO/demo/projects" "$REPO/demo/state" || FAIL=1 ;;
esac
exit "$FAIL"
