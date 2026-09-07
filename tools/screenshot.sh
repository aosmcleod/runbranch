#!/usr/bin/env bash
#
# Screenshot the app, unattended, against the fictional demo data.
#
#   ./tools/screenshot.sh [out.png]
#
# The app photographs its own window (see Screenshot in app/RunBranch.swift),
# which is the only approach that survived: it captures what the window server
# composited, so glass and vibrancy are real.
#
# It needs Screen Recording permission, and macOS will not prompt for it on an
# ad-hoc-signed binary launched from a terminal. Add it by hand:
#   System Settings > Privacy & Security > Screen Recording > + > Runbranch.app

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/docs/img/screenshot.png}"
APP="$REPO/Runbranch.app/Contents/MacOS/RunBranch"

[ -x "$APP" ] || { echo "build the app first: ./make-app.sh" >&2; exit 1; }
[ -d "$REPO/demo" ] || "$REPO/tools/make-demo.sh" >/dev/null

RB_PROJECTS_DIR="$REPO/demo/projects" RB_HOME="$REPO/demo/state" \
RB_MY_EMAILS="dana@example.com" "$APP" --screenshot "$OUT"

[ -s "$OUT" ] || { echo "no screenshot written" >&2; exit 1; }
echo "wrote $OUT"
