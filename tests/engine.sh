#!/usr/bin/env bash
#
# Engine tests. Every case here corresponds to a bug that actually happened
# during development, which is the only reason a test earns its keep.
#
#   ./tests/engine.sh          run them
#   ./tests/engine.sh -v       show each assertion
#
# They run against a throwaway fixture repo and a throwaway state directory,
# never against real projects.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO/runbranch.sh"
VERBOSE="${1:-}"

TMP="$(mktemp -d)"
export RB_HOME="$TMP/state"
export RB_PROJECTS_DIR="$TMP/projects"
export RB_MY_EMAILS="tester@example.com"
# Do not hijack the browser. A suite that steals focus is a suite people stop
# running, and this one starts a real server on purpose.
export RB_NO_OPEN=1
mkdir -p "$RB_PROJECTS_DIR" "$RB_HOME"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); [ "$VERBOSE" = -v ] && printf '  ok    %s\n' "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not contain [$3]" ;; esac; }

# --- fixture ---------------------------------------------------------------
FIX="$TMP/fixture"
mkdir -p "$FIX/public"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.email tester@example.com
git -C "$FIX" config user.name Tester
echo hi > "$FIX/public/index.html"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "feat: the first commit"
git -C "$FIX" checkout -q -b feature/one
echo more >> "$FIX/public/index.html"
git -C "$FIX" commit -qam "feat(one): a second commit on a branch"
git -C "$FIX" checkout -q main

cat > "$RB_PROJECTS_DIR/fixture.conf" <<CONF
# A comment that must survive every write.
NAME="Fixture"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4321:/:python3 -m http.server 4321 --directory public"
SYMBOL="cube"
CONF

echo "==> projects and config"
is "lists the fixture"         "$("$ENGINE" projects | cut -f1)" "fixture"
is "reads the display name"    "$("$ENGINE" get fixture | awk -F'\t' '$1=="NAME"{print $2}')" "Fixture"
is "reads the symbol"          "$("$ENGINE" get fixture | awk -F'\t' '$1=="SYMBOL"{print $2}')" "cube"
is "doctor passes"             "$("$ENGINE" doctor fixture >/dev/null 2>&1; echo $?)" "0"

echo "==> branch data"
is "finds both branches"       "$("$ENGINE" branches fixture | wc -l | tr -d ' ')" "2"
is "marks the default branch"  "$("$ENGINE" branches fixture | awk -F'\t' '$1=="main"{print $8}')" "1"
is "attributes them to me"     "$("$ENGINE" branches fixture | awk -F'\t' '$1=="main"{print $4}')" "me"
# Regression: `git for-each-ref` does not interpret \t, so the row used to
# collapse into a single field.
is "row has every column"      "$("$ENGINE" branches fixture | head -1 | awk -F'\t' '{print NF}')" "13"
has "carries the commit subject" "$("$ENGINE" branches fixture | awk -F'\t' '$1=="feature/one"{print $11}')" "a second commit"

echo "==> set preserves the file"
BEFORE_COMMENTS=$(grep -c '^#' "$RB_PROJECTS_DIR/fixture.conf")
"$ENGINE" set fixture SYMBOL "globe" >/dev/null 2>&1
is "writes a simple key"       "$("$ENGINE" get fixture | awk -F'\t' '$1=="SYMBOL"{print $2}')" "globe"
is "keeps the comments"        "$(grep -c '^#' "$RB_PROJECTS_DIR/fixture.conf")" "$BEFORE_COMMENTS"
"$ENGINE" set fixture NEWKEY "added" >/dev/null 2>&1
is "appends an absent key"     "$(grep -c '^NEWKEY=' "$RB_PROJECTS_DIR/fixture.conf")" "1"

# Regression: the first version passed the value through `awk -v`, which cannot
# carry a newline, and emptied the file.
echo "==> set survives a multi-line value"
MULTI="$(printf 'web:4321:/:python3 -m http.server 4321\001api:4322:/:python3 -m http.server 4322')"
"$ENGINE" set fixture TARGETS "$MULTI" >/dev/null 2>&1
is "both targets present"      "$("$ENGINE" presets fixture | wc -l | tr -d ' ')" "3"
is "file is not empty"         "$([ -s "$RB_PROJECTS_DIR/fixture.conf" ] && echo yes)" "yes"
is "still loads"               "$("$ENGINE" doctor fixture >/dev/null 2>&1; echo $?)" "0"

# Regression: a bad write used to leave a broken config behind.
echo "==> set reverts a config that will not load"
cp "$RB_PROJECTS_DIR/fixture.conf" "$TMP/before.conf"
"$ENGINE" set fixture REPO "" >/dev/null 2>&1
is "refuses the write"         "$(diff -q "$TMP/before.conf" "$RB_PROJECTS_DIR/fixture.conf" >/dev/null; echo $?)" "0"

echo "==> presets and targets"
"$ENGINE" set fixture TARGETS "web:4321:/:true" >/dev/null 2>&1
"$ENGINE" set fixture ALWAYS "" >/dev/null 2>&1
is "one target, one preset"    "$("$ENGINE" presets fixture | tr -d '\n')" "web"

# Not tested: that RB_NO_OPEN suppresses the browser. Whether `open` ran is not
# observable from here, and a test that greps output text for it would assert
# on the wording rather than the behaviour. RB_NO_OPEN is exported at the top
# of this file, which is what stops the suite hijacking a browser tab.

echo "==> favourites"
is "not favourite by default"  "$("$ENGINE" projects | awk -F'\t' '$1=="fixture"{print $6}')" "0"
"$ENGINE" favourite fixture on >/dev/null 2>&1
is "pinning sticks"            "$("$ENGINE" projects | awk -F'\t' '$1=="fixture"{print $6}')" "1"
"$ENGINE" favourite fixture on >/dev/null 2>&1
is "pinning twice is idempotent" "$(grep -c fixture "$RB_HOME/favourites")" "1"
"$ENGINE" favourite fixture off >/dev/null 2>&1
is "unpinning sticks"          "$("$ENGINE" projects | awk -F'\t' '$1=="fixture"{print $6}')" "0"

echo "==> paths"
is "paths reports five fields" "$("$ENGINE" paths fixture | awk -F'\t' '{print NF}')" "5"
is "and six with a ref"        "$("$ENGINE" paths fixture main | awk -F'\t' '{print NF}')" "6"

echo "==> state when nothing runs"
is "reports idle"              "$("$ENGINE" state fixture)" "idle"
is "status exits non-zero"     "$("$ENGINE" status fixture >/dev/null 2>&1; echo $?)" "1"

# The presets case above left TARGETS pointing at `true`, which exits at once.
# Put a real server back before testing a real run.
"$ENGINE" set fixture TARGETS "web:4321:/:python3 -m http.server 4321 --directory public" >/dev/null 2>&1

echo "==> worktree lifecycle"
"$ENGINE" run fixture feature/one web >/dev/null 2>&1
is "state says running"        "$("$ENGINE" state fixture | head -1 | cut -f1)" "run"
is "the branch is recorded"    "$("$ENGINE" state fixture | head -1 | cut -f2)" "feature/one"
is "the target answers"        "$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost:4321/)" "200"
is "the worktree is detached"  "$(git -C "$FIX" worktree list | grep -c 'detached HEAD')" "1"
is "the checkout did not move" "$(git -C "$FIX" rev-parse --abbrev-ref HEAD)" "main"
"$ENGINE" stop fixture >/dev/null 2>&1
sleep 1
is "stops cleanly"             "$("$ENGINE" state fixture)" "idle"
is "the port is released"      "$(lsof -nP -iTCP:4321 -sTCP:LISTEN -t 2>/dev/null | head -1)" ""

echo "==> reclaim clears stale state"
"$ENGINE" run fixture main web >/dev/null 2>&1
PGID=$("$ENGINE" state fixture | awk -F'\t' '$1=="target"{print $5}')
kill -KILL -"$PGID" 2>/dev/null
sleep 1
# `state` already reports idle once the pids are gone -- it checks liveness,
# not the file. What is stale is the state FILE, which is what reclaim removes.
is "the state file lingers"    "$([ -f "$RB_HOME/fixture/state" ] && echo yes)" "yes"
is "state reports idle"        "$("$ENGINE" state fixture)" "idle"
"$ENGINE" reclaim fixture >/dev/null 2>&1
is "reclaim removes the file"  "$([ -f "$RB_HOME/fixture/state" ] && echo yes || echo no)" "no"

echo "==> a project's own run is not a conflict with itself"
# Switching branches within a project was being stopped by a warning about a
# port it was about to free itself: do_run stops whatever the project has going
# before it starts anything.
cat > "$RB_PROJECTS_DIR/selfrun.conf" <<CONF
NAME="Self Run"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4995:/:python3 -m http.server {port} --directory public"
CONF
cat > "$RB_PROJECTS_DIR/rival.conf" <<CONF
NAME="Rival"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4995:/:python3 -m http.server {port} --directory public"
CONF
"$ENGINE" run selfrun main web >/dev/null 2>&1
is "the run is up" "$(curl -sfo /dev/null -w '%{http_code}' http://localhost:4995/ 2>/dev/null)" "200"

"$ENGINE" check-ports selfrun web >/dev/null 2>&1
is "no conflict with its own run" "$?" "0"
# Switching to another branch must therefore just work.
"$ENGINE" run selfrun feature/one web >/dev/null 2>&1
is "so switching branches works"  "$?" "0"

# A different project on the same port is still a conflict.
"$ENGINE" check-ports rival web >/dev/null 2>&1
is "another project still conflicts" "$?" "1"

"$ENGINE" stop selfrun >/dev/null 2>&1
rm -f "$RB_PROJECTS_DIR/selfrun.conf" "$RB_PROJECTS_DIR/rival.conf"
rm -rf "$RB_HOME/selfrun" "$RB_HOME/rival"

echo "==> a port held from a checkout is attributed to that project"
# The common real case: a dev server started by a terminal or an agent, inside
# the project's own checkout. Reporting that as "another app" is unhelpful when
# we can see whose it is.
( cd "$FIX" && python3 -m http.server 4991 --directory public >/dev/null 2>&1 & echo $! > "$TMP/outside.pid" )
sleep 2
cat > "$RB_PROJECTS_DIR/attrib.conf" <<CONF
NAME="Attrib"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4991:/:python3 -m http.server {port} --directory public"
CONF
ATT="$("$ENGINE" check-ports attrib web 2>&1)" || true
has "names the project"        "$ATT" "attrib"
has "says it is not ours"      "$ATT" "outside"
RUNMSG="$("$ENGINE" run attrib main web 2>&1)" || true
has "and says so in the error" "$RUNMSG" "started outside Runbranch"

echo "==> a project already running outside Runbranch shows as running"
# Finding out by failing to start is a poor way to find out. If the project's
# own server is up, say so.
cat > "$RB_PROJECTS_DIR/adopt.conf" <<CONF
NAME="Adopt"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4993:/:python3 -m http.server {port} --directory public"
CONF
is "idle before anything runs" "$("$ENGINE" state adopt 2>&1)" "idle"
( cd "$FIX" && python3 -m http.server 4993 --directory public >/dev/null 2>&1 & )
sleep 2
ADOPTED="$("$ENGINE" state adopt 2>&1)"
has "reports a run"            "$ADOPTED" "run	"
has "flagged as adopted"       "$ADOPTED" "	1	1"
has "with the live target"     "$ADOPTED" "target	web	4993"
# It must not claim someone else's port as this project's run.
cat > "$RB_PROJECTS_DIR/notmine.conf" <<CONF
NAME="Not Mine"
REPO="$TMP/other-repo"
DEFAULT_BRANCH="main"
TARGETS="web:4993:/:true"
CONF
mkdir -p "$TMP/other-repo" && git -C "$TMP/other-repo" init -q -b main
is "and not for another project" "$("$ENGINE" state notmine 2>&1)" "idle"
pkill -f "http.server 4993" 2>/dev/null || true
rm -f "$RB_PROJECTS_DIR/adopt.conf" "$RB_PROJECTS_DIR/notmine.conf"

echo "==> kill-port only ends what belongs to a project"
REFUSE="$("$ENGINE" kill-port 1 2>&1)" || true
has "refuses an unattributable process" "$REFUSE" "does not belong to a project"
is  "and launchd survives"              "$(ps -p 1 >/dev/null 2>&1 && echo alive)" "alive"
BADPID="$("$ENGINE" kill-port notanumber 2>&1)" || true
has "rejects a non-numeric pid"         "$BADPID" "Not a process id"
# The attributable one it will end.
OUTSIDE_PID="$(lsof -nP -iTCP:4991 -sTCP:LISTEN -t 2>/dev/null | head -1)"
"$ENGINE" kill-port "$OUTSIDE_PID" >/dev/null 2>&1
sleep 1
curl -sfo /dev/null http://localhost:4991/ 2>/dev/null
is  "ends one it can attribute"         "$?" "7"
rm -f "$RB_PROJECTS_DIR/attrib.conf"
pkill -f "http.server 4991" 2>/dev/null || true

echo "==> an in-place run uses the checkout, and only starts servers"
# The point of in-place is that uncommitted work is live, so the assertion is
# that a file written in the checkout and never committed is served.
git -C "$FIX" checkout -q main
printf 'uncommitted\n' > "$FIX/public/scratch.txt"
cat > "$RB_PROJECTS_DIR/inplace.conf" <<CONF
NAME="In Place"
REPO="$FIX"
DEFAULT_BRANCH="main"
INSTALL="false"
TARGETS="web:4981:/:python3 -m http.server {port} --directory public"
CONF
# INSTALL is deliberately `false`: if an in-place run ever runs it, the run
# fails and this test says so.
"$ENGINE" run inplace main web --in-place >/dev/null 2>&1
is "starts without running INSTALL" "$?" "0"
is "serves uncommitted work" \
   "$(curl -sf http://localhost:4981/scratch.txt 2>/dev/null | tr -d '\n')" "uncommitted"
is "state records the mode"   "$(grep -c '^IN_PLACE=1$' "$RB_HOME/inplace/state" 2>/dev/null)" "1"
is "state points at the checkout" \
   "$(grep '^WORKTREE=' "$RB_HOME/inplace/state" | cut -d= -f2-)" "$FIX"
is "and made no worktree"     "$([ -d "$RB_HOME/inplace/worktrees" ] && ls "$RB_HOME/inplace/worktrees" | wc -l | tr -d ' ' || echo 0)" "0"
"$ENGINE" stop inplace >/dev/null 2>&1
sleep 1
curl -sfo /dev/null http://localhost:4981/ 2>/dev/null
is "stop really stops it"     "$?" "7"
# Never the checkout: the working tree and its untracked files must survive.
is "the checkout is intact"   "$([ -f "$FIX/public/scratch.txt" ] && echo yes || echo no)" "yes"
is "and still on its branch"  "$(git -C "$FIX" rev-parse --abbrev-ref HEAD)" "main"

echo "==> in-place refuses a branch the checkout is not on"
OFFBR="$("$ENGINE" run inplace feature/one web --in-place 2>&1)" || true
has "says what is checked out" "$OFFBR" "has main checked out"
has "offers the way forward"   "$OFFBR" "git switch"
rm -f "$RB_PROJECTS_DIR/inplace.conf" "$FIX/public/scratch.txt"
rm -rf "$RB_HOME/inplace"

echo "==> branches say where they are checked out"
# Field 9 is the checkout branch, field 13 a worktree someone made themselves.
# git will not let one branch be checked out twice, so a branch sitting in
# another worktree cannot be run from ours either — worth saying rather than
# letting the run fail.
git -C "$FIX" checkout -q -b "held/elsewhere" 2>/dev/null || true
git -C "$FIX" checkout -q main
OUTSIDE="$TMP/outside-worktree"
git -C "$FIX" worktree add -q "$OUTSIDE" "held/elsewhere" 2>/dev/null

ROWS="$("$ENGINE" branches fixture 2>/dev/null)"
CUR_ROW="$(printf '%s\n' "$ROWS" | awk -F'\t' '$1=="main"{print $9}')"
is "the checkout branch is flagged" "$CUR_ROW" "1"
ELSEWHERE="$(printf '%s\n' "$ROWS" | awk -F'\t' '$1=="held/elsewhere"{print $13}')"
has "a foreign worktree is reported" "$ELSEWHERE" "outside-worktree"
# Our own worktrees must not be reported as foreign, or every branch we have
# ever run would look like it was checked out somewhere else.
OURS="$(printf '%s\n' "$ROWS" | awk -F'\t' '$1=="feature/one"{print $13}')"
is "our own worktrees are not" "$OURS" ""

git -C "$FIX" worktree remove --force "$OUTSIDE" 2>/dev/null || true

echo "==> a shifted run tells the server where to listen"
# Two routes, because a config cannot be assumed to have anticipated a shift:
# {port} in the command when it names one, and PORT in the environment when it
# does not. The second covers most dev servers without any config change.
cat > "$RB_PROJECTS_DIR/envport.conf" <<CONF
NAME="Env Port"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4951:/:python3 -c 'import os,http.server,functools; h=functools.partial(http.server.SimpleHTTPRequestHandler, directory=\"public\"); http.server.HTTPServer((\"\",int(os.environ[\"PORT\"])),h).serve_forever()'"
CONF
CHK="$("$ENGINE" check-ports envport web 2>&1)" || true
is "no conflict when the port is free" "$CHK" ""

python3 -m http.server 4951 --directory "$FIX/public" >/dev/null 2>&1 &
ENVBLOCK=$!
sleep 2
CHK="$("$ENGINE" check-ports envport web 2>&1)" || true
has "reports the move as env-only" "$CHK" "	env"

"$ENGINE" run envport main web 1 >/dev/null 2>&1
is "shifts without {port} in the command" "$?" "0"
is "and the shifted port answers" \
   "$(curl -sfo /dev/null -w '%{http_code}' http://localhost:4952/ 2>/dev/null)" "200"
"$ENGINE" stop envport >/dev/null 2>&1
kill "$ENVBLOCK" 2>/dev/null || true
pkill -f "http.server 4951" 2>/dev/null || true

echo "==> a shifted run says so when the server ignores PORT"
cat > "$RB_PROJECTS_DIR/hardport.conf" <<CONF
NAME="Hard Port"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4953:/:python3 -m http.server 4953 --directory public"
CONF
python3 -m http.server 4953 --directory "$FIX/public" >/dev/null 2>&1 &
HARDBLOCK=$!
sleep 2
IGN="$("$ENGINE" run hardport main web 1 2>&1)" || true
has "blames the right thing"  "$IGN" "does not say where to"
has "names the port it tried" "$IGN" "4954"
has "suggests {port}"         "$IGN" "{port}"
kill "$HARDBLOCK" 2>/dev/null || true
pkill -f "http.server 4953" 2>/dev/null || true
rm -f "$RB_PROJECTS_DIR/envport.conf" "$RB_PROJECTS_DIR/hardport.conf"
rm -rf "$RB_HOME/envport" "$RB_HOME/hardport"

echo "==> two branches that slug the same get separate worktrees"
# slug_for is lossy, so feat/a-b and feat/a+b both want the directory
# "feat-a-b". Sharing it mostly works — each run re-checks-out the ref — but
# remove-worktree on one would delete the other's, and a per-run database keyed
# the same way would be shared between branches with divergent migrations.
git -C "$FIX" checkout -q -b "feat/a-b" 2>/dev/null || true
git -C "$FIX" checkout -q main
git -C "$FIX" checkout -q -b "feat/a+b" 2>/dev/null || true
git -C "$FIX" checkout -q main

"$ENGINE" run fixture "feat/a-b" web >/dev/null 2>&1
"$ENGINE" stop fixture >/dev/null 2>&1
"$ENGINE" run fixture "feat/a+b" web >/dev/null 2>&1
"$ENGINE" stop fixture >/dev/null 2>&1

WT_COUNT="$(ls "$RB_HOME/fixture/worktrees" 2>/dev/null | grep -c '^feat-a-b')" || WT_COUNT=0
is "each ref gets its own worktree" "$WT_COUNT" "2"
is "the first keeps the plain name" \
   "$([ -d "$RB_HOME/fixture/worktrees/feat-a-b" ] && echo yes || echo no)" "yes"
# And each records itself as the owner, which is how the collision is detected.
OWNERS="$(cat "$RB_HOME/fixture/meta/"feat-a-b*.ref 2>/dev/null | sort | tr '\n' ' ')"
has "both refs are recorded" "$OWNERS" "feat/a+b feat/a-b"

echo "==> a config that will not parse says so"
# An unclosed quote used to let bash print its own diagnostics and then apply
# half the file, so the error that surfaced was whatever happened to be missing
# — an unclosed quote reported itself as "sets no REPO".
printf 'NAME="Broken\nREPO=%s\n' "$FIX" > "$RB_PROJECTS_DIR/broken.conf"
BROKEN="$("$ENGINE" branches broken 2>&1)" || true
has "names the syntax error"     "$BROKEN" "syntax error"
has "quotes the offending line"  "$BROKEN" "line 1"
case "$BROKEN" in
  *"sets no REPO"*) bad "does not misdiagnose it" "still blamed a missing REPO" ;;
  *) ok "does not misdiagnose it" ;;
esac
is "and does not leave it usable" "$("$ENGINE" doctor broken >/dev/null 2>&1; echo $?)" "1"
rm -f "$RB_PROJECTS_DIR/broken.conf"

echo "==> port conflicts name the run holding the port"
# Two projects that both default to the same port is the common case: Vite
# picks 5173 for everything, so a second project collides with the first.
mkdir -p "$RB_HOME/holder/worktrees/main"
cat > "$RB_PROJECTS_DIR/holder.conf" <<CONF
NAME="Holder"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4399:/:python3 -m http.server 4399"
CONF
cat > "$RB_PROJECTS_DIR/wants.conf" <<CONF
NAME="Wants"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4399:/:python3 -m http.server 4399"
CONF
# Hold the port from inside the other project's worktree, which is what makes
# it identifiable as ours.
( cd "$RB_HOME/holder/worktrees/main" && python3 -m http.server 4399 >/dev/null 2>&1 & echo $! > "$TMP/holder.pid" )
sleep 2
CONFLICT="$("$ENGINE" run wants main web 2>&1)" || true
has "names the project holding the port" "$CONFLICT" "running holder here"
has "offers to stop the right project"   "$CONFLICT" "stop holder"
case "$CONFLICT" in
  *"stop wants"*) bad "does not send you after the wrong project" "suggested stopping wants" ;;
  *) ok "does not send you after the wrong project" ;;
esac
kill "$(cat "$TMP/holder.pid")" 2>/dev/null || true
pkill -f "http.server 4399" 2>/dev/null || true
rm -f "$RB_PROJECTS_DIR/holder.conf" "$RB_PROJECTS_DIR/wants.conf"
rm -rf "$RB_HOME/holder"

echo "==> a run can be shifted onto free ports"
cat > "$RB_PROJECTS_DIR/shift.conf" <<CONF
NAME="Shift"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4601:/:python3 -m http.server {port} --directory public"
CONF
# Hold the declared port, so the shift is the only way to start.
python3 -m http.server 4601 --directory "$FIX/public" >/dev/null 2>&1 &
BLOCKER=$!
sleep 2

CHECK="$("$ENGINE" check-ports shift web 2>&1)" || true
has "check-ports names the target"     "$CHECK" "web"
has "check-ports reports the port"     "$CHECK" "4601"
has "check-ports says overridable"     "$CHECK" "	1"
has "check-ports suggests an offset"   "$CHECK" "OFFSET"

# Without an offset it must refuse rather than start something broken.
"$ENGINE" run shift main web >/dev/null 2>&1
is "refuses while the port is held" "$?" "1"

# With one, {port} carries the shift into the command, so the server really
# listens where the health check is looking.
"$ENGINE" run shift main web 1 >/dev/null 2>&1
is "starts on the shifted port" "$?" "0"
SHIFTED="$("$ENGINE" status shift 2>&1)"
has "status shows the shifted port"  "$SHIFTED" "4602"
is  "the shifted port answers"       "$(curl -sfo /dev/null -w '%{http_code}' http://localhost:4602/ 2>/dev/null)" "200"
RECORDED="$(grep -c '^PORT_OFFSET=1$' "$RB_HOME/shift/state" 2>/dev/null)" || RECORDED=0
is  "the offset is recorded"         "$RECORDED" "1"

# And stop has to look at the real port, not the declared one.
"$ENGINE" stop shift >/dev/null 2>&1
sleep 1
is "stop clears the shifted run" "$([ -f "$RB_HOME/shift/state" ] && echo yes || echo no)" "no"
# curl writes the code even when it fails, so `|| echo` appends to it rather
# than replacing it. Ask about the exit status instead.
curl -sfo /dev/null http://localhost:4602/ 2>/dev/null
is  "the shifted port is free"    "$?" "7"

kill "$BLOCKER" 2>/dev/null || true
pkill -f "http.server 4601" 2>/dev/null || true
rm -f "$RB_PROJECTS_DIR/shift.conf"; rm -rf "$RB_HOME/shift"

echo "==> doctor reports ports claimed by more than one project"
cat > "$RB_PROJECTS_DIR/twinA.conf" <<CONF
NAME="Twin A"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4501:/:python3 -m http.server 4501"
CONF
cat > "$RB_PROJECTS_DIR/twinB.conf" <<CONF
NAME="Twin B"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4501:/:python3 -m http.server 4501"
CONF
DOC="$("$ENGINE" doctor 2>&1)" || true
has "names the shared port"    "$DOC" "4501"
has "names both projects"      "$DOC" "twinA twinB"
# `sort -n -u` here would collapse every line sharing a port into one, so the
# count could never exceed 1 and the warning could never fire.
has "warns at all"             "$DOC" "claimed by more than one project"
rm -f "$RB_PROJECTS_DIR/twinB.conf"
DOC="$("$ENGINE" doctor 2>&1)" || true
case "$DOC" in
  *"claimed by more than one project"*) bad "silent when ports are distinct" "still warned" ;;
  *) ok "silent when ports are distinct" ;;
esac
rm -f "$RB_PROJECTS_DIR/twinA.conf"

echo "==> remove"
# A second project, so removing it cannot disturb the fixture the rest of the
# suite depends on.
cat > "$RB_PROJECTS_DIR/spare.conf" <<CONF
NAME="Spare"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4322:/:python3 -m http.server 4322 --directory public"
CONF
mkdir -p "$RB_HOME/spare/logs"
: > "$RB_HOME/spare/logs/web.log"
echo spare >> "$RB_HOME/favourites"

REMOVE_OUT="$("$ENGINE" remove spare 2>&1)"
has "says the repository was untouched" "$REMOVE_OUT" "repository was not touched"
is  "deletes the config"      "$([ -f "$RB_PROJECTS_DIR/spare.conf" ] && echo yes || echo no)" "no"
is  "deletes the state"       "$([ -d "$RB_HOME/spare" ] && echo yes || echo no)" "no"
is  "leaves the repo alone"   "$([ -d "$FIX/.git" ] && echo yes || echo no)" "yes"
# grep -c prints 0 and still exits 1 when it matches nothing, so a `|| echo 0`
# here appends a second line rather than supplying a default.
FAV_LEFT="$(grep -cxF spare "$RB_HOME/favourites" 2>/dev/null)" || FAV_LEFT=0
is  "unpins the favourite"    "$FAV_LEFT" "0"
is  "the fixture survives"    "$([ -f "$RB_PROJECTS_DIR/fixture.conf" ] && echo yes || echo no)" "yes"

# Removing the config from under a live run orphans the servers, leaving
# nothing that knows how to stop them.
#
# Driven through an actual run on purpose. The first version of this test wrote
# a fake state file at the path the implementation looked for — and the
# implementation looked for "current" while the state file is called "state", so
# the test passed while the guard never fired once.
cat > "$RB_PROJECTS_DIR/busy.conf" <<CONF
NAME="Busy"
REPO="$FIX"
DEFAULT_BRANCH="main"
TARGETS="web:4323:/:python3 -m http.server {port} --directory public"
CONF
"$ENGINE" run busy main web >/dev/null 2>&1
is  "the run really started"   "$(curl -sfo /dev/null -w '%{http_code}' http://localhost:4323/ 2>/dev/null)" "200"
BUSY_OUT="$("$ENGINE" remove busy 2>&1)"; BUSY_RC=$?
is  "refuses while running"    "$BUSY_RC" "1"
is  "keeps a running project"  "$([ -f "$RB_PROJECTS_DIR/busy.conf" ] && echo yes || echo no)" "yes"
is  "leaves the state alone"   "$([ -f "$RB_HOME/busy/state" ] && echo yes || echo no)" "yes"
has "names the command to fix it" "$BUSY_OUT" "stop busy"
# And once stopped it goes, so the guard is not simply refusing everything.
"$ENGINE" stop busy >/dev/null 2>&1
"$ENGINE" remove busy >/dev/null 2>&1
is  "removes it once stopped"  "$([ -f "$RB_PROJECTS_DIR/busy.conf" ] && echo yes || echo no)" "no"
rm -rf "$RB_HOME/busy" "$RB_PROJECTS_DIR/busy.conf"

UNKNOWN_OUT="$("$ENGINE" remove nosuchproject 2>&1)"
has "rejects an unknown project" "$UNKNOWN_OUT" "No such project"

echo "==> propose reads a repo"
has "detects the default branch" "$("$ENGINE" propose "$FIX")" 'DEFAULT_BRANCH="main"'
has "names the repo"             "$("$ENGINE" propose "$FIX")" "REPO="
# Regression: with no lockfile the guess used to be a command that does not
# exist, which failed minutes into a run instead of immediately.
has "admits when it cannot tell" "$("$ENGINE" propose "$FIX")" "REPLACE-ME"

echo "==> a run says how far the branch has moved since it started"
"$ENGINE" run fixture feature/one web >/dev/null 2>&1
behind() { "$ENGINE" state fixture | awk -F'\t' '$1=="behind"{print $2}'; }
is "a fresh run is not behind"  "$(behind)" "0"
# Move the branch on with plumbing rather than a checkout. The ref is checked
# out in the run's worktree, and an empty commit onto the tip is what someone
# else pushing looks like from here.
NEWC="$(git -C "$FIX" commit-tree "$(git -C "$FIX" rev-parse 'feature/one^{tree}')" \
        -p feature/one -m "feat(one): a commit made after the run started")"
git -C "$FIX" update-ref refs/heads/feature/one "$NEWC"
# The bug behind this: a worktree is pinned to the commit it was made at, and
# Refresh — which only re-reads pull request metadata — was mistaken for a way
# to pick up new commits. So a run sat on an old commit looking current.
is "and says so once it has"    "$(behind)" "1"
"$ENGINE" update fixture >/dev/null 2>&1
is "update catches it up"       "$(behind)" "0"
is "the run is still up"        "$("$ENGINE" state fixture | awk -F'\t' '$1=="run"{print 1}')" "1"
is "on the same ref"            "$("$ENGINE" state fixture | awk -F'\t' '$1=="run"{print $2}')" "feature/one"
"$ENGINE" stop fixture >/dev/null 2>&1

echo "==> update refuses a run that is already on the working tree"
git -C "$FIX" checkout -q main
cat > "$RB_PROJECTS_DIR/drift.conf" <<CONF
NAME="Drift"
REPO="$FIX"
DEFAULT_BRANCH="main"
INSTALL="false"
TARGETS="web:4982:/:python3 -m http.server {port} --directory public"
CONF
"$ENGINE" run drift main web --in-place >/dev/null 2>&1
UPD="$("$ENGINE" update drift 2>&1)" || true
has "says why there is nothing to do" "$UPD" "already on the working tree"
is  "and leaves the run alone"        "$("$ENGINE" state drift | awk -F'\t' '$1=="run"{print 1}')" "1"

echo "==> an in-place run notices the branch being switched underneath it"
# Starting in place refuses a ref the checkout is not on, and until now nothing
# checked again. Switch the branch in a terminal, an editor or an agent and the
# servers keep running, now serving something else, while Runbranch reports the
# branch it started with — and hot reload picks the new code up, which is what
# makes it convincing as well as wrong.
switched() { "$ENGINE" state drift | awk -F'\t' '$1=="switched"{print $2}'; }
is "says nothing while it is right" "$(switched)" ""
git -C "$FIX" checkout -q -b drift/elsewhere
is "reports the branch now on disk" "$(switched)" "drift/elsewhere"
is "and still reports the run's own" \
   "$("$ENGINE" state drift | awk -F'\t' '$1=="run"{print $2}')" "main"
git -C "$FIX" checkout -q main
is "and stops saying it once back"  "$(switched)" ""
# A worktree run has nothing to be switched out from under it.
"$ENGINE" stop drift >/dev/null 2>&1
"$ENGINE" run fixture feature/one web >/dev/null 2>&1
is "a worktree run never reports it" \
   "$("$ENGINE" state fixture | awk -F'\t' '$1=="switched"{print $2}')" ""
"$ENGINE" stop fixture >/dev/null 2>&1
rm -f "$RB_PROJECTS_DIR/drift.conf"; rm -rf "$RB_HOME/drift"

echo "==> prune-gone removes worktrees whose ref is gone, and spares the rest"
git -C "$FIX" checkout -q -b doomed/branch
git -C "$FIX" checkout -q main
"$ENGINE" run fixture doomed/branch web >/dev/null 2>&1
"$ENGINE" stop fixture >/dev/null 2>&1
WT="$RB_HOME/fixture/worktrees"
# Not a count of everything on disk: earlier cases leave worktrees behind on
# purpose, and asserting a total here made this test about them instead.
is "the doomed worktree exists" "$([ -d "$WT/doomed-branch" ] && echo yes || echo no)" "yes"
git -C "$FIX" branch -D doomed/branch >/dev/null 2>&1
# "gone" and not "merged": a squash-merge leaves a branch looking unmerged, so
# a merged-branch heuristic would either miss the common case or delete work.
PRUNED="$("$ENGINE" prune-gone fixture 2>&1)"
has "it says which ref went"    "$PRUNED" "doomed/branch no longer exists"
is "the dead one is gone"       "$([ -d "$WT/doomed-branch" ] && echo yes || echo no)" "no"
is "the live one is spared"     "$([ -d "$WT/feature-one" ] && echo yes || echo no)" "yes"
is "and again does nothing"     "$("$ENGINE" prune-gone fixture 2>&1 | awk -F'\t' '$1=="pruned"{print $2}')" "0"
# Refusing to delete what is in use matters more than the pruning does.
"$ENGINE" run fixture feature/one web >/dev/null 2>&1
git -C "$FIX" update-ref -d refs/heads/feature/one
is "a running worktree is never pruned" \
   "$("$ENGINE" prune-gone fixture 2>&1 | awk -F'\t' '$1=="pruned"{print $2}')" "0"
is "and it is still on disk"    "$([ -d "$WT/feature-one" ] && echo yes || echo no)" "yes"
"$ENGINE" stop fixture >/dev/null 2>&1

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
