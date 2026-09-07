#!/usr/bin/env bash
#
# Screenshot every documented screen, unattended, against the fictional demo
# data. Nothing real appears in any of them.
#
#   ./tools/screenshot.sh            all scenes into docs/img/
#   ./tools/screenshot.sh main       just one
#
# The app photographs its own window (see Screenshot in app/RunBranch.swift).
# It needs Screen Recording permission, and macOS will not prompt for it on an
# ad-hoc-signed binary launched from a terminal — add it by hand:
#   System Settings > Privacy & Security > Screen Recording > + > Runbranch.app
#
# Note the grant is tied to the code signature, and an ad-hoc signature changes
# on every build. Re-granting after a rebuild is expected until the app is
# signed with a real identity.

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
