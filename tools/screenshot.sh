#!/usr/bin/env bash
#
# Screenshot every documented screen, unattended, against the fictional demo
# data. Nothing real appears in any of them.
#
#   ./tools/screenshot.sh            all scenes into docs/img/
#   ./tools/screenshot.sh main       just one
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

# Onboarding has to be shot against an empty config directory, since the
# welcome screen only appears when nothing is declared.
EMPTY="$(mktemp -d)"
trap 'rm -rf "$EMPTY"' EXIT
mkdir -p "$EMPTY/projects" "$EMPTY/state"

# macOS ships no timeout(1), and a wedged capture must not wedge the pipeline.
run_limited() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

shoot() {  # file, scene, projects-dir, state-dir
  local file="$1" scene="$2" pdir="$3" sdir="$4"
  # A previous instance still holding a window makes the next capture fail.
  pkill -f 'RunBranch --screenshot' 2>/dev/null
  rm -f "$OUT/$file"
  RB_PROJECTS_DIR="$pdir" RB_HOME="$sdir" RB_MY_EMAILS="dana@example.com" \
  RB_NO_OPEN=1 run_limited 45 "$APP" --screenshot "$OUT/$file" --scene "$scene" 2>&1 \
    | grep -v AttributeGraph | sed 's/^/    /'
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
exit "$FAIL"
