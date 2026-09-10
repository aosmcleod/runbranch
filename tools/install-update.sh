#!/bin/bash
#
# Swap a downloaded Runbranch in for the running one, and start it again.
#
#   install-update.sh <pid> <new-app> <installed-app> <mountpoint> <dmg>
#
# Run detached by the app itself, immediately before it quits. It cannot do
# this work in process: the bundle being replaced is the one the code is
# running from, and the copy has to happen after that code has stopped.
#
# The app has already mounted the image and checked that what is on it is a
# Runbranch of the version it expected. This script does the part that cannot
# be undone, so every failure below puts the old app back and opens it.

set -u

pid="${1:?pid}"
src="${2:?new app}"
dst="${3:?installed app}"
mount="${4:?mountpoint}"
dmg="${5:-}"

# A swap that goes wrong leaves no other trace: the app that could have
# reported it is the thing being replaced, and the app that comes back has no
# idea an update was attempted. So write one line per step, next to this script.
LOG="${TMPDIR:-/tmp}/runbranch-update.log"
say() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
# Truncated per attempt rather than appended to for ever: what anyone wants
# from this file is why the update they just tried did not happen.
: > "$LOG"
say "swapping $dst for $src (pid $pid)"

cleanup() {
  [ -d "$mount" ] && hdiutil detach "$mount" -quiet 2>/dev/null
  [ -n "$dmg" ] && rm -f "$dmg"
  return 0
}

# Wait for it to go. `open -W` is not available to us — we were launched by the
# process we are waiting on — so poll, and stop waiting after ten seconds in
# case it is wedged on a dialog rather than quitting.
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  say "still running after ${waited}00ms; asking it to stop"
  kill "$pid" 2>/dev/null
  sleep 0.5
else
  say "it exited after ${waited}00ms"
fi

# Aside rather than deleted, and in the same directory so the move is a rename
# rather than a copy across volumes. This is the only thing standing between a
# failed copy and no Runbranch at all.
backup="$dst.replaced-$$"
if ! mv "$dst" "$backup" 2>/dev/null; then
  say "FAILED to move the installed app aside; nothing changed"
  cleanup
  open "$dst" 2>/dev/null
  exit 1
fi

if ! cp -R "$src" "$dst" 2>/dev/null; then
  say "FAILED to copy the new app in; putting the old one back"
  rm -rf "$dst"
  mv "$backup" "$dst"
  cleanup
  open "$dst" 2>/dev/null
  exit 1
fi

# The new bundle came off a disk image this process mounted, not out of a
# browser, so it carries no quarantine flag. Clearing it anyway costs nothing
# and covers the case where the image itself arrived quarantined.
xattr -dr com.apple.quarantine "$dst" 2>/dev/null

rm -rf "$backup"
cleanup
say "swapped; reopening"
open "$dst" 2>/dev/null
