#!/usr/bin/env bash
#
# frankly-launcher — a Dock-able runner for the Frankly (Function Studio) demo.
#
# The problem: demoing out of ~/Development/work/Studio means the demo competes
# with whatever is being edited there. Switching branches either fails on
# uncommitted work or silently changes what the person at the keyboard sees.
# And .env.local is gitignored, so a fresh branch starts with no config and
# everything 401s or cannot reach Postgres.
#
# The fix, and the whole idea: one throwaway git worktree per branch. The
# working checkout is NEVER touched. Everything below is ergonomics on top.
#
#   ~/Development/work/Studio                    <- never modified
#   ~/Development/work/.frankly-demo/<branch>/   <- throwaway worktree
#
# Bash + osascript only. No Node, no Homebrew packages, no Electron.
#
# Usage:
#   frankly-launcher.sh                      interactive (native pickers)
#   frankly-launcher.sh run <ref> <target>   prepare + start (web|admin|both)
#   frankly-launcher.sh stop                 stop the running demo
#   frankly-launcher.sh status               print status; exit 0 if running
#   frankly-launcher.sh cleanup              remove throwaway worktrees
#
# Written for bash 3.2 (what macOS ships at /bin/bash): no associative arrays,
# no mapfile, no ${var,,}, and no here-documents inside $( ) -- 3.2 mis-parses
# those, which is why every osascript call below uses repeated -e arguments.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration. Every value can be overridden by an env var, mostly so the
# script is testable somewhere other than a real machine.
# ---------------------------------------------------------------------------

STUDIO="${FRANKLY_STUDIO:-$HOME/Development/work/Studio}"
DEMO_ROOT="${FRANKLY_DEMO_ROOT:-$HOME/Development/work/.frankly-demo}"

# Pinned deliberately. `docker compose` derives its project name from the
# directory it runs in, so running it from a worktree would create project
# "fx977-unvendor-fxui" with its own EMPTY volumes -- and then collide on
# docker-compose.yml's fixed `container_name: studio-postgres`. Pinning the
# project keeps every worktree pointed at the one real database.
COMPOSE_PROJECT="${FRANKLY_COMPOSE_PROJECT:-studio}"

# Fixed ports. apps/api defaults API_PORT to 4000, apps/web is `next dev
# --port 3000`, apps/admin is `--port 3002`. .env.local's CORS origins and
# NEXT_PUBLIC_API_URL are pinned to these, so they are not really negotiable.
PORT_API=4000
PORT_WEB=3000
PORT_ADMIN=3002

STATE_FILE="$DEMO_ROOT/.state"
RECENT_FILE="$DEMO_ROOT/.recent"
LOG_DIR="$DEMO_ROOT/logs"

APP_NAME="Frankly Launcher"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Sign-in only works on localhost. Clerk dev instances accept exactly ONE
# primary frontend origin and the customer web claims localhost:3000, so
# admin.studio.test:3002 and portal.studio.test:3001 cannot also be Clerk
# origins on the same instance. Open localhost URLs; never studio.test.
URL_WEB="http://localhost:$PORT_WEB"
URL_ADMIN="http://localhost:$PORT_ADMIN"
URL_API="http://localhost:$PORT_API"

# ---------------------------------------------------------------------------
# Output. When we have a terminal we print; when we do not (launched from the
# Dock) the same message goes to a dialog. Errors always name the command that
# fixes them -- that is the entire reason this script exists.
# ---------------------------------------------------------------------------

if [ -t 1 ]; then HAVE_TTY=1; else HAVE_TTY=0; fi

if [ "$HAVE_TTY" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_OFF=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLU" "$C_OFF" "$C_BLD" "$*" "$C_OFF"; }
ok()   { printf '    %sok%s   %s\n' "$C_GRN" "$C_OFF" "$*"; }
info() { printf '        %s\n' "$*"; }
dim()  { printf '        %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '    %swarn%s %s\n' "$C_YEL" "$C_OFF" "$*"; }

# AppleScript string escaping. AppleScript has no \n escape, so any newline is
# spliced in with (ASCII character 10) by the caller that needs one.
as_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Dialogs raised by `osascript` wear a generic script icon unless told
# otherwise, which makes them look like something went wrong rather than like
# this app asking a question. make-app.sh drops a PNG next to the .icns for
# exactly this. Absent (running straight from the repo with no bundle built),
# every dialog still works -- it just wears the default icon.
ICON_PNG="$(dirname "$SELF")/Frankly Launcher.app/Contents/Resources/AppIcon.png"
icon_clause() {
  [ -f "$ICON_PNG" ] || return 0
  printf ' with icon (POSIX file "%s")' "$(as_quote "$ICON_PNG")"
}

# A modal alert, for real failures.
gui_alert() {
  osascript >/dev/null 2>&1 \
    -e 'tell me to activate' \
    -e "display alert \"$(as_quote "$1")\" message \"$(as_quote "$2")\" as critical buttons {\"OK\"} default button \"OK\""
}

gui_notify() {
  osascript >/dev/null 2>&1 \
    -e "display notification \"$(as_quote "$2")\" with title \"$(as_quote "$1")\""
}

# Fail loudly. $1 is what went wrong, $2 (optional) is the command that fixes
# it. Both reach the user whether they are looking at a terminal or the Dock.
die() {
  local msg="$1" fix="${2:-}"
  if [ "$HAVE_TTY" = 1 ]; then
    printf '\n%s%s FAILED %s %s\n' "$C_BLD" "$C_RED" "$C_OFF" "$msg" >&2
    if [ -n "$fix" ]; then
      printf '\n%sFix:%s\n\n    %s\n\n' "$C_BLD" "$C_OFF" "$fix" >&2
    fi
    hold_terminal_open
  else
    local body="$msg"
    if [ -n "$fix" ]; then
      body="$msg

Fix:
$fix"
    fi
    gui_alert "$APP_NAME" "$body"
  fi
  exit 1
}

# A Dock-launched Terminal window would otherwise vanish on failure, taking the
# error message with it. Only pauses in that case; never in a normal shell.
hold_terminal_open() {
  if [ "${FRANKLY_IN_TERMINAL:-0}" = 1 ] && [ "$HAVE_TTY" = 1 ]; then
    printf '%sPress return to close this window.%s ' "$C_DIM" "$C_OFF"
    read -r _ || true
  fi
}

# A yes/no question. Terminal prompt when there is a terminal, dialog when not.
ask() {
  local question="$1" default_no="${2:-0}" reply hint def out
  if [ "$HAVE_TTY" = 1 ]; then
    hint='[Y/n]'; [ "$default_no" = 1 ] && hint='[y/N]'
    printf '\n    %s %s ' "$question" "$hint"
    read -r reply || reply=''
    case "$reply" in
      [yY]*) return 0 ;;
      [nN]*) return 1 ;;
      '')    [ "$default_no" = 1 ] && return 1 || return 0 ;;
      *)     return 1 ;;
    esac
  fi
  def='Yes'; [ "$default_no" = 1 ] && def='No'
  out=$(osascript 2>/dev/null \
    -e 'tell me to activate' \
    -e "button returned of (display dialog \"$(as_quote "$question")\" buttons {\"No\", \"Yes\"} default button \"$def\" with title \"$(as_quote "$APP_NAME")\"$(icon_clause))")
  [ "$out" = "Yes" ]
}

# The native list picker. Prints the chosen line(s), one per line; returns 1 on
# cancel. $2 is "single" or "multiple", $3 is the confirm button's label, and
# the remaining args are the rows.
#
# Single-select preselects the first row, so the common case -- start the
# branch you demoed last -- is Return with nothing else touched.
choose() {
  local prompt="$1" mode="$2" oklabel="$3"; shift 3
  local list='' item multi='false' preselect='' out
  for item in "$@"; do
    list="$list\"$(as_quote "$item")\", "
  done
  list="${list%, }"
  [ -z "$list" ] && return 1
  if [ "$mode" = multiple ]; then
    multi='true'
  else
    preselect=' default items {item 1 of theList}'
  fi
  out=$(osascript 2>/dev/null \
    -e 'tell me to activate' \
    -e "set theList to {$list}" \
    -e "set theChoice to choose from list theList with title \"$(as_quote "$APP_NAME")\" with prompt \"$(as_quote "$prompt")\"$preselect OK button name \"$(as_quote "$oklabel")\" cancel button name \"Cancel\" multiple selections allowed $multi" \
    -e 'if theChoice is false then error number -128' \
    -e "set AppleScript's text item delimiters to (ASCII character 10)" \
    -e 'return theChoice as text')
  [ -z "$out" ] && return 1
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# PATH hardening
#
# An app launched from the Dock inherits launchd's PATH -- /usr/bin:/bin:
# /usr/sbin:/sbin -- and NOT the one your shell builds. Under it, docker
# (/usr/local/bin), pnpm and gh (/opt/homebrew/bin) and node (fnm, whose bin
# directory is generated per shell session and has no fixed location) are all
# invisible. The launcher would then report them as "not installed" while they
# sit right there, which is exactly the sort of unactionable error this tool
# exists to avoid.
#
# There are two layers of defence. The .app wrapper runs this script through
# `zsh -lic`, so your real shell environment is loaded and PATH matches your
# terminal exactly. This function is the second layer: it makes the script work
# when it is invoked from anywhere with a bare environment.
# ---------------------------------------------------------------------------

harden_path() {
  local dir
  for dir in \
    /opt/homebrew/bin \
    /opt/homebrew/sbin \
    /usr/local/bin \
    "$HOME/.local/bin" \
    "$HOME/Library/pnpm" \
    /Applications/Docker.app/Contents/Resources/bin
  do
    [ -d "$dir" ] || continue
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) PATH="$PATH:$dir" ;;
    esac
  done
  export PATH

  # node and corepack come from fnm, which mints a bin directory per shell
  # session -- there is no stable path to add, so ask fnm where it put one.
  if ! command -v node >/dev/null 2>&1 && command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env 2>/dev/null)" || true
  fi
}

# ---------------------------------------------------------------------------
# Host preflight
# ---------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  die "\`$1\` is not on PATH.

The launcher already looks in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin,
~/Library/pnpm, Docker.app's bundled bin, and asks fnm for its node directory.
So $1 is either genuinely missing, or installed somewhere unusual -- in which
case running the launcher from your terminal will pick up your own PATH." "$2"
}

# Studio pins its Node version in .nvmrc and package.json engines. A lower one
# on PATH fails deep inside a build, where the message names neither Node nor
# the version, so check it here where the fix is one line.
check_node_version() {
  local want have
  want=$(tr -dc '0-9' < "$STUDIO/.nvmrc" 2>/dev/null | head -c 3)
  [ -n "$want" ] || return 0
  have=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)
  [ -n "$have" ] || return 0
  [ "$have" -ge "$want" ] 2>/dev/null && { ok "node $have (Studio pins $want)"; return 0; }
  die "Node $have is on PATH, but Studio pins Node $want in .nvmrc." \
    "fnm install $want && fnm default $want"
}

preflight_host() {
  harden_path
  require_cmd git    'xcode-select --install'
  require_cmd docker 'Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
  require_cmd node   'fnm install 24 && fnm default 24'
  require_cmd pnpm   'corepack enable'
  check_node_version

  [ -d "$STUDIO/.git" ] || die \
    "No git repository at $STUDIO." \
    "FRANKLY_STUDIO=/path/to/Studio $SELF"

  docker info >/dev/null 2>&1 || die \
    "Docker is installed but the daemon is not responding." \
    'open -a Docker    # then wait for the whale icon to settle'

  # The one file a fresh worktree cannot get from git. Without it every app
  # 401s on Clerk or fails to reach Postgres, and it reads as a broken branch.
  [ -f "$STUDIO/.env.local" ] || die \
    "$STUDIO/.env.local does not exist, so there is nothing to copy into a worktree.

It is gitignored by design. Create it in the main checkout first." \
    "cd $STUDIO && pnpm bootstrap"
}

# Read-only view of the working checkout. The ONLY things this script ever does
# in $STUDIO are: read refs, read .env.local, and git-worktree metadata
# operations (add/remove/prune/list), which touch .git but never the working
# tree. No checkout, no stash, no fetch unless explicitly asked for.
studio_git() { git -C "$STUDIO" "$@"; }

# Branch names carry slashes; directories should not.
slug_for() { printf '%s' "$1" | sed -e 's#^origin/##' -e 's#[^A-Za-z0-9._-]#-#g'; }

worktree_path() { printf '%s/%s' "$DEMO_ROOT" "$(slug_for "$1")"; }
meta_file()     { printf '%s/meta/%s.ref' "$DEMO_ROOT" "$(slug_for "$1")"; }

# ---------------------------------------------------------------------------
# Ports. One demo at a time is a hard constraint (shared Postgres), so a busy
# port is either our own demo or the user's own dev server. Never kill the
# latter -- name it and say what to do.
# ---------------------------------------------------------------------------

port_holder() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1; }

port_holder_desc() {
  local pid="$1"
  ps -o pid=,command= -p "$pid" 2>/dev/null | sed -e 's/^ *//' | cut -c1-110
}

ports_for_target() {
  case "$1" in
    web)   printf '%s %s\n' "$PORT_API" "$PORT_WEB" ;;
    admin) printf '%s %s\n' "$PORT_API" "$PORT_ADMIN" ;;
    both)  printf '%s %s %s\n' "$PORT_API" "$PORT_WEB" "$PORT_ADMIN" ;;
  esac
}

ensure_ports_free() {
  local target="$1" port pid busy=''
  for port in $(ports_for_target "$target"); do
    pid=$(port_holder "$port")
    [ -n "$pid" ] && busy="$busy
  port $port  ->  $(port_holder_desc "$pid")"
  done
  [ -z "$busy" ] && return 0
  die "Something is already listening on a port this demo needs:
$busy

If that is your own dev server in $STUDIO, leave it alone and stop it yourself
-- two dev servers on the same Postgres is exactly the deadlock this launcher
exists to avoid. If it is a leftover demo, stop it." \
    "$SELF stop        # a leftover demo
    kill <pid>        # your own dev server, on purpose"
}

# ---------------------------------------------------------------------------
# Branch discovery. Everything here is a read against $STUDIO.
# ---------------------------------------------------------------------------

studio_current_branch() { studio_git rev-parse --abbrev-ref HEAD 2>/dev/null; }

# Most-recently-demoed refs first. Plain newline-delimited file, newest on top.
recent_refs() { [ -f "$RECENT_FILE" ] && cat "$RECENT_FILE" || true; }

remember_ref() {
  local ref="$1" tmp
  mkdir -p "$DEMO_ROOT"
  tmp="$RECENT_FILE.tmp"
  { printf '%s\n' "$ref"; recent_refs | grep -vxF "$ref" || true; } | head -8 >"$tmp"
  mv "$tmp" "$RECENT_FILE"
}

# ---------------------------------------------------------------------------
# Worktree preparation
# ---------------------------------------------------------------------------

# Worktrees are created DETACHED at the ref's tip, never as a checkout of the
# branch itself. Two reasons: git refuses to check out a branch that is already
# checked out elsewhere (demoing the branch you are working on is the common
# case), and a demo runner has no business holding a branch ref it might move.
# Sets WORKTREE. Does not print it: this function writes progress to stdout.
WORKTREE=''
prepare_worktree() {
  local ref="$1" wt tip
  wt="$(worktree_path "$ref")"

  tip=$(studio_git rev-parse --verify --quiet "$ref^{commit}")
  [ -n "$tip" ] || die \
    "\`$ref\` does not resolve to a commit in $STUDIO." \
    "cd $STUDIO && git fetch origin"

  step "Worktree  $wt"
  mkdir -p "$DEMO_ROOT/meta" "$LOG_DIR"

  if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
    local at
    at=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [ "$at" = "$tip" ]; then
      ok "already at $(printf '%.9s' "$tip")"
    else
      info "updating $(printf '%.9s' "$at") -> $(printf '%.9s' "$tip")"
      # --force discards nothing of value: this tree is throwaway and nobody
      # edits it. It does clear any stray build output that would confuse a
      # branch switch.
      git -C "$wt" checkout --detach --force "$tip" >/dev/null 2>&1 || die \
        "Could not move the worktree to $ref." \
        "$SELF cleanup        # remove it and let the launcher rebuild it"
      ok "moved to $(printf '%.9s' "$tip")"
    fi
  else
    # A directory left behind by a previous `worktree remove` failure would
    # make `worktree add` refuse; prune first so the common case self-heals.
    studio_git worktree prune >/dev/null 2>&1
    safe_rm_worktree "$wt"
    info "creating worktree (detached at $(printf '%.9s' "$tip"))"
    studio_git worktree add --detach "$wt" "$tip" >/dev/null 2>&1 || die \
      "\`git worktree add\` failed for $ref." \
      "cd $STUDIO && git worktree add --detach '$wt' '$tip'"
    ok "created"
  fi

  printf '%s\n' "$ref" >"$(meta_file "$ref")"

  # Worktrees do not inherit untracked files, and .env.local is gitignored.
  # Copy it EVERY time, not just on create: it changes in the main checkout
  # and a stale copy is indistinguishable from a broken branch.
  cp "$STUDIO/.env.local" "$wt/.env.local"
  ok ".env.local copied from the main checkout"

  WORKTREE="$wt"
}

# rm -rf with a leash: refuses anything that is not a direct child of
# DEMO_ROOT, so a bad ref or an unset variable cannot walk off the reservation.
safe_rm_worktree() {
  local path="$1" parent
  [ -n "$path" ] || return 1
  [ -e "$path" ] || return 0
  parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd)"
  if [ "$parent" != "$DEMO_ROOT" ] || [ "$path" = "$DEMO_ROOT" ]; then
    die "Refusing to delete $path -- it is not a throwaway worktree under $DEMO_ROOT." \
      "Remove it by hand if that is really what you want."
  fi
  rm -rf "$path"
}

# ---------------------------------------------------------------------------
# Dependencies
#
# @function-point/fxui comes from GitHub Packages. The repo's root .npmrc maps
# the scope but deliberately carries NO auth line (a project .npmrc outranks
# ~/.npmrc, so an unset ${VAR} there would resolve to an empty token and shadow
# a working one). Auth therefore has to be in ~/.npmrc, and a default
# `gh auth login` does not grant read:packages -- so the failure mode is a bare
# 401 from pnpm several minutes into an install. Check it up front instead.
# ---------------------------------------------------------------------------

GH_PACKAGES_REFRESH='gh auth refresh -h github.com -s read:packages'

npmrc_has_token() {
  grep -Eq '^//npm\.pkg\.github\.com/:_authToken=.+' "$HOME/.npmrc" 2>/dev/null
}

gh_has_read_packages() {
  command -v gh >/dev/null 2>&1 || return 1
  gh api -i user 2>/dev/null \
    | tr -d '\r' \
    | grep -i '^x-oauth-scopes:' \
    | grep -q 'read:packages'
}

check_registry_auth() {
  local wt="$1"
  if npmrc_has_token; then
    ok "GitHub Packages token present in ~/.npmrc"
    return 0
  fi

  # No token. Two different fixes depending on whether gh can supply one.
  if gh_has_read_packages; then
    die "~/.npmrc has no GitHub Packages token, so installing @function-point/fxui
will 401.

Your gh token already has read:packages -- the repo's own script will write
~/.npmrc from it." \
      "cd $wt && node scripts/ensure-npmrc.mjs"
  fi

  die "~/.npmrc has no GitHub Packages token and your gh token lacks the
read:packages scope, so installing @function-point/fxui will 401.

A default \`gh auth login\` grants gist / project / read:org / repo / workflow
and NOT read:packages, which is why this catches people." \
    "$GH_PACKAGES_REFRESH
    cd $wt && node scripts/ensure-npmrc.mjs"
}

# @heroui-pro/react is a gated package with a postinstall that needs its own
# credential. Without it the package installs as a STUB -- the install succeeds,
# and the missing types only surface later at typecheck or as a blank render.
# Not fatal here, but never silent.
check_heroui_auth() {
  if [ -n "${HEROUI_AUTH_TOKEN:-}" ]; then
    ok "HEROUI_AUTH_TOKEN set"
    return 0
  fi
  if [ -d "$HOME/.heroui" ]; then
    ok "HeroUI Pro credentials found in ~/.heroui"
    return 0
  fi
  warn "No HEROUI_AUTH_TOKEN and no ~/.heroui."
  dim  "@heroui-pro/react will install as a stub and the UI may not render."
  dim  "Fix:  npx heroui-pro login"
  ask "Continue anyway?" 1 || die "Stopped before install." 'npx heroui-pro login'
}

install_deps() {
  local wt="$1" log="$LOG_DIR/install.log" rc
  step "Dependencies"
  check_registry_auth "$wt"
  check_heroui_auth

  # A worktree starts with no node_modules. This is the slow step -- minutes on
  # a cold tree -- so its output is streamed rather than swallowed. A silent
  # spinner here is how a launcher gets mistaken for a hung one.
  info "pnpm install --frozen-lockfile   (first run on a branch takes a few minutes)"
  info "logging to $log"
  printf '\n'
  ( cd "$wt" && pnpm install --frozen-lockfile 2>&1 ) | tee "$log"
  rc=${PIPESTATUS[0]}
  printf '\n'
  [ "$rc" = 0 ] && { ok "dependencies installed"; return 0; }

  # Turn the two failures that actually happen into instructions.
  if grep -qiE 'ERR_PNPM_FETCH_401|401 Unauthorized|npm\.pkg\.github\.com.*(401|Unauthorized)' "$log"; then
    die "pnpm got a 401 from GitHub Packages while fetching @function-point/fxui." \
      "$GH_PACKAGES_REFRESH
    cd $wt && node scripts/ensure-npmrc.mjs && pnpm install --frozen-lockfile"
  fi
  if grep -qiE 'ERR_PNPM_OUTDATED_LOCKFILE|frozen-lockfile' "$log"; then
    die "pnpm-lock.yaml on this branch does not match its package.json files, so
--frozen-lockfile refused to install.

That is a real inconsistency on the branch, not a launcher problem -- installing
without the lockfile guard would demo something the branch does not describe." \
      "cd $wt && pnpm install        # accept the drift, then re-run the launcher"
  fi
  die "pnpm install failed. The last lines are above; the full log is at $log." \
    "cd $wt && pnpm install --frozen-lockfile"
}

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

# -p pins the compose project. See the COMPOSE_PROJECT comment at the top: this
# is what stops a worktree from creating a second, empty Postgres.
compose() {
  local wt="$1"; shift
  docker compose -p "$COMPOSE_PROJECT" -f "$wt/docker-compose.yml" "$@"
}

bring_up_infra() {
  local wt="$1"
  step "Infrastructure  (compose project: $COMPOSE_PROJECT)"
  info "docker compose up -d --wait postgres valkey"
  compose "$wt" up -d --wait postgres valkey >/dev/null 2>&1 || die \
    "Postgres/Valkey did not come up healthy." \
    "docker compose -p $COMPOSE_PROJECT -f $wt/docker-compose.yml up -d postgres valkey
    docker compose -p $COMPOSE_PROJECT -f $wt/docker-compose.yml logs postgres"
  ok "postgres and valkey healthy"
}

pg_container() { compose "$1" ps -q postgres 2>/dev/null | head -1; }

# Count of migrations this branch expects, from the drizzle journal.
migrations_expected() {
  local journal="$1/packages/db/drizzle/meta/_journal.json"
  [ -f "$journal" ] || { printf '0'; return; }
  grep -o '"tag"' "$journal" | wc -l | tr -d ' '
}

# Count of migrations the shared database has actually applied.
migrations_applied() {
  local cid n
  cid=$(pg_container "$1")
  [ -n "$cid" ] || { printf '0'; return; }
  n=$(docker exec "$cid" psql -U studio -d studio -tAc \
        'select count(*) from drizzle.__drizzle_migrations' 2>/dev/null | tr -d ' ')
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

# There is ONE database and every branch shares it. Migrating forward is fine;
# demoing a branch that is BEHIND the database is the case that quietly
# misbehaves, and no migration undoes it.
handle_migrations() {
  local wt="$1" want applied
  step "Database"
  want=$(migrations_expected "$wt")
  applied=$(migrations_applied "$wt")
  info "branch expects $want migrations; database has applied $applied"

  if [ "$applied" -gt "$want" ]; then
    warn "The database is AHEAD of this branch by $((applied - want)) migration(s)."
    dim  "Another branch migrated it. Those changes do not roll back, and this"
    dim  "branch's code has never seen them -- expect odd behaviour."
    dim  "Clean slate (DESTROYS all local data, then needs a re-seed):"
    dim  "  docker compose -p $COMPOSE_PROJECT -f $wt/docker-compose.yml down -v"
    dim  "  then re-run this launcher, then: cd $wt && pnpm seed:account"
    ask "Demo this branch anyway?" 1 || die "Stopped before starting servers." \
      "docker compose -p $COMPOSE_PROJECT -f $wt/docker-compose.yml down -v"
    return 0
  fi

  if [ "$want" -gt "$applied" ]; then
    info "applying $((want - applied)) migration(s) -- this mutates the shared database"
    ( cd "$wt" && pnpm --filter @fs/db db:migrate ) || die \
      "Migrations failed." \
      "cd $wt && pnpm --filter @fs/db db:migrate"
    ok "migrations applied"
    return 0
  fi

  ok "schema up to date"
}

# ---------------------------------------------------------------------------
# Servers
#
# Each server is started in its OWN PROCESS GROUP (`set -m` gives a background
# job a fresh pgid equal to its pid). That matters for stopping: the api runs
# under `tsx --watch`, which RESPAWNS its node child if you kill only the child.
# Signalling the whole group takes down pnpm, tsx and node together.
# ---------------------------------------------------------------------------

# Sets STARTED_PID (which is also the process-group id). Does not print it:
# this function writes progress to stdout.
STARTED_PID=''
start_server() {
  # Split deliberately: bash expands every argument to `local` BEFORE it
  # assigns any of them, so referencing $name in the same statement that
  # declares it reads the (unset) global and trips `set -u`.
  local wt="$1" name="$2" filter="$3"
  local log="$LOG_DIR/$name.log" pid
  mkdir -p "$LOG_DIR"
  : >"$log"
  set -m
  ( cd "$wt" && exec nohup pnpm --filter "$filter" dev ) >"$log" 2>&1 &
  pid=$!
  # Detach from the job table: keeps the shell from printing "[1]+ Terminated"
  # over the output later, and keeps the server alive once this script exits.
  disown %% 2>/dev/null || true
  set +m
  sleep 1
  kill -0 "$pid" 2>/dev/null || {
    printf '\n'; tail -20 "$log"; printf '\n'
    die "$name exited immediately. Its log is above and at $log." \
      "cd $wt && pnpm --filter $filter dev"
  }
  ok "$name started (pgid $pid) -> $log"
  STARTED_PID="$pid"
}

# Poll until the port answers. Any HTTP status counts: Next dev returns 404 for
# a route it has not compiled yet, and that still means "the server is up".
wait_for_http() {
  local url="$1" label="$2" timeout="$3" pid="$4" waited=0 code
  info "waiting for $label at $url"
  while [ "$waited" -lt "$timeout" ]; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      return 2
    fi
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != 000 ]; then
      ok "$label responding (HTTP $code after ${waited}s)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
    # A Next.js cold compile is genuinely slow. Say so rather than look stuck.
    case "$waited" in 20|60|120) dim "still waiting... (${waited}s; first compile is slow)" ;; esac
  done
  return 1
}

write_state() {
  mkdir -p "$DEMO_ROOT"
  {
    printf 'REF=%s\n'       "$1"
    printf 'WORKTREE=%s\n'  "$2"
    printf 'TARGET=%s\n'    "$3"
    printf 'API_PID=%s\n'   "$4"
    printf 'WEB_PID=%s\n'   "$5"
    printf 'ADMIN_PID=%s\n' "$6"
    printf 'STARTED=%s\n'   "$(date '+%Y-%m-%d %H:%M:%S')"
  } >"$STATE_FILE"
}

# Populates S_REF / S_WORKTREE / S_TARGET / S_API_PID / S_WEB_PID / S_ADMIN_PID
# / S_STARTED. Returns 1 when there is no state file.
load_state() {
  S_REF=''; S_WORKTREE=''; S_TARGET=''
  S_API_PID=''; S_WEB_PID=''; S_ADMIN_PID=''; S_STARTED=''
  [ -f "$STATE_FILE" ] || return 1
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      REF)       S_REF="$val" ;;
      WORKTREE)  S_WORKTREE="$val" ;;
      TARGET)    S_TARGET="$val" ;;
      API_PID)   S_API_PID="$val" ;;
      WEB_PID)   S_WEB_PID="$val" ;;
      ADMIN_PID) S_ADMIN_PID="$val" ;;
      STARTED)   S_STARTED="$val" ;;
    esac
  done <"$STATE_FILE"
  return 0
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# True when a demo this launcher started is still up.
demo_running() {
  load_state || return 1
  alive "$S_API_PID" || alive "$S_WEB_PID" || alive "$S_ADMIN_PID"
}

start_demo() {
  local wt="$1" ref="$2" target="$3"
  local api_pid='' web_pid='' admin_pid='' rc

  step "Servers"
  start_server "$wt" api "@fs/api";     api_pid="$STARTED_PID"
  case "$target" in
    web)   start_server "$wt" web "@fs/web";     web_pid="$STARTED_PID" ;;
    admin) start_server "$wt" admin "@fs/admin"; admin_pid="$STARTED_PID" ;;
    both)  start_server "$wt" web "@fs/web";     web_pid="$STARTED_PID"
           start_server "$wt" admin "@fs/admin"; admin_pid="$STARTED_PID" ;;
  esac
  write_state "$ref" "$wt" "$target" "$api_pid" "$web_pid" "$admin_pid"

  step "Waiting"
  # /live is the shallow liveness probe -- static 200, no DB, no auth.
  wait_for_http "$URL_API/live" "api" 120 "$api_pid"; rc=$?
  [ "$rc" = 0 ] || server_failed api "$rc" "$LOG_DIR/api.log" "$wt" "@fs/api"

  local opened=''
  if [ -n "$web_pid" ]; then
    wait_for_http "$URL_WEB" "web" 240 "$web_pid"; rc=$?
    [ "$rc" = 0 ] || server_failed web "$rc" "$LOG_DIR/web.log" "$wt" "@fs/web"
    opened="$URL_WEB"
  fi
  if [ -n "$admin_pid" ]; then
    wait_for_http "$URL_ADMIN" "admin" 240 "$admin_pid"; rc=$?
    [ "$rc" = 0 ] || server_failed admin "$rc" "$LOG_DIR/admin.log" "$wt" "@fs/admin"
    [ -z "$opened" ] && opened="$URL_ADMIN"
  fi

  step "Ready"
  # localhost only -- see the URL_WEB comment. studio.test breaks admin sign-in.
  [ -n "$web_pid" ]   && info "web    $URL_WEB"
  [ -n "$admin_pid" ] && info "admin  $URL_ADMIN"
  info "api    $URL_API"
  [ -n "$opened" ] && open "$opened" >/dev/null 2>&1
  gui_notify "$APP_NAME" "Demo running: $ref ($target)"
}

server_failed() {
  local name="$1" rc="$2" log="$3" wt="$4" filter="$5"
  printf '\n'; tail -25 "$log"; printf '\n'
  local why="$name never answered within the timeout"
  [ "$rc" = 2 ] && why="$name exited while starting"
  stop_demo quiet
  die "$why. The last log lines are above; the full log is at $log." \
    "cd $wt && pnpm --filter $filter dev        # run it in the foreground to see why"
}

# ---------------------------------------------------------------------------
# Stopping
# ---------------------------------------------------------------------------

# Signal the whole process group, not the pid. `kill -TERM -<pgid>` is what
# takes tsx --watch down with its child instead of letting it respawn.
kill_group() {
  local pgid="$1" waited=0
  [ -n "$pgid" ] || return 0
  kill -0 "$pgid" 2>/dev/null || return 0
  kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
  while [ "$waited" -lt 12 ]; do
    kill -0 "$pgid" 2>/dev/null || return 0
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
}

stop_demo() {
  local quiet="${1:-}"
  if ! load_state; then
    [ "$quiet" = quiet ] || info "No demo is recorded as running."
    return 0
  fi
  [ "$quiet" = quiet ] || step "Stopping  $S_REF ($S_TARGET)"
  kill_group "$S_API_PID"
  kill_group "$S_WEB_PID"
  kill_group "$S_ADMIN_PID"
  rm -f "$STATE_FILE"

  # Anything still on a demo port after that is a stray from an earlier run.
  # Only reap it when it is clearly ours -- a process whose command line points
  # into the throwaway worktree root. Never touch the user's own dev server.
  local port pid cmd left=''
  for port in "$PORT_API" "$PORT_WEB" "$PORT_ADMIN"; do
    pid=$(port_holder "$port")
    [ -n "$pid" ] || continue
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$cmd" in
      *"$DEMO_ROOT"*) kill -TERM "$pid" 2>/dev/null || true ;;
      *) left="$left
  port $port  ->  $(port_holder_desc "$pid")" ;;
    esac
  done
  if [ -n "$left" ] && [ "$quiet" != quiet ]; then
    warn "Still listening, and not started by this launcher:$left"
    dim  "Left alone on purpose. Stop it yourself if it is in the way: kill <pid>"
  fi
  [ "$quiet" = quiet ] || ok "stopped"
}

print_status() {
  if demo_running; then
    printf '\n%sDemo running%s\n' "$C_BLD" "$C_OFF"
    printf '  branch    %s\n'  "$S_REF"
    printf '  running   %s\n'  "$S_TARGET"
    printf '  worktree  %s\n'  "$S_WORKTREE"
    printf '  since     %s\n'  "$S_STARTED"
    alive "$S_API_PID"   && printf '  api       %s\n' "$URL_API"
    alive "$S_WEB_PID"   && printf '  web       %s\n' "$URL_WEB"
    alive "$S_ADMIN_PID" && printf '  admin     %s\n' "$URL_ADMIN"
    printf '  logs      %s\n\n' "$LOG_DIR"
    return 0
  fi
  printf '\nNo demo running.\n\n'
  return 1
}

# ---------------------------------------------------------------------------
# Branch data
#
# Deliberately NO network. An earlier draft asked `gh pr list` which PRs were
# merged -- 1.7s on every launch. It turns out git already knows: this repo
# merges PRs with merge commits (not squash), so a merged branch's commits are
# reachable from origin/development and `git branch --merged` names it. Two
# local git calls, no round trip, and the picker opens instantly.
#
# The tradeoff, and it is the honest one: "merged" is measured against the
# origin/development you last fetched. A branch merged since your last fetch
# still looks live. That is what the Fetch button is for.
# ---------------------------------------------------------------------------

# Every address Alec has authored commits under. A branch is "mine" when its
# tip carries one of them.
MY_EMAILS="${FRANKLY_MY_EMAILS:-alecmcleod@icloud.com alec.mcleod@functionpoint.com alec@mcleod.co}"

DEFAULT_BRANCH="${FRANKLY_DEFAULT_BRANCH:-development}"

# The repo pushes branches faster than anyone reads them -- 636 remote, 428 of
# them unmerged. "Everyone else" is an escape hatch, not a browser, so it shows
# the most recent slice and says so.
OTHER_LIMIT="${FRANKLY_OTHER_LIMIT:-80}"

# Writes "ref|group|age|meta|merged" to $1. group is default|mine|other.
collect_branch_data() {
  local out="$1" now ready_slugs dir current
  now=$(date +%s)
  current=$(studio_current_branch)

  # Which branches already have a built worktree -- the fast ones to start.
  ready_slugs=' '
  for dir in "$DEMO_ROOT"/*; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in meta|logs|.*) continue ;; esac
    ready_slugs="$ready_slugs$(basename "$dir") "
  done

  {
    studio_git branch --merged "origin/$DEFAULT_BRANCH" --format='M|%(refname:short)' 2>/dev/null
    studio_git branch -r --merged "origin/$DEFAULT_BRANCH" --format='M|%(refname:short)' 2>/dev/null
    studio_git for-each-ref --sort=-committerdate \
      --format='L|%(refname:short)|%(authoremail)|%(committerdate:unix)' refs/heads 2>/dev/null
    studio_git for-each-ref --sort=-committerdate \
      --format='R|%(refname:short)|%(authoremail)|%(committerdate:unix)' refs/remotes/origin 2>/dev/null
  } | awk -F'|' \
        -v now="$now" -v emails="$MY_EMAILS" -v ready="$ready_slugs" \
        -v current="$current" -v defbr="$DEFAULT_BRANCH" -v olimit="$OTHER_LIMIT" '
    function age(ts,   d) {
      d = now - ts
      if (d < 3600)   return int(d / 60) "m"
      if (d < 86400)  return int(d / 3600) "h"
      if (d < 2592000) return int(d / 86400) "d"
      return int(d / 2592000) "mo"
    }
    function slug(r) { gsub(/^origin\//, "", r); gsub(/[^A-Za-z0-9._-]/, "-", r); return r }
    function mine(email,   i, n, parts) {
      n = split(emails, parts, " ")
      for (i = 1; i <= n; i++) if (index(email, parts[i]) > 0) return 1
      return 0
    }
    function emit(ref, group, ts,   meta, m) {
      meta = ""
      if (index(ready, " " slug(ref) " ") > 0) meta = "ready"
      if (ref == current) meta = (meta == "" ? "open in Studio" : meta " · in Studio")
      m = (ref in merged) ? 1 : 0
      print ref "|" group "|" age(ts) "|" meta "|" m
    }
    $1 == "M" { merged[$2] = 1; next }
    $1 == "L" {
      seenlocal[$2] = 1
      if ($2 == defbr) { emit($2, "default", $4); next }
      emit($2, mine($3) ? "mine" : "other", $4)
      next
    }
    $1 == "R" {
      if ($2 == "origin" || $2 == "origin/HEAD") next
      short = $2; sub(/^origin\//, "", short)
      # A local branch already stands for its remote twin.
      if (short == defbr || seenlocal[short]) next
      if (mine($3)) { emit($2, "mine", $4); next }
      if (others++ >= olimit) next
      emit($2, "other", $4)
    }
  ' > "$out"

}

# ---------------------------------------------------------------------------
# Branch picking
# ---------------------------------------------------------------------------

# Labels are "<ref>  <note>". The ref is recovered by cutting at the first
# double space, so notes must never contain one at the front.
label_ref() { printf '%s' "${1%%"  "*}"; }

FETCH_LABEL='↻   Fetch from origin'
TYPE_LABEL='⌕   Type a branch name...'

# This repo carries 500+ remote branches. All of them in one `choose from list`
# is not a picker, it is a haystack -- so remotes are capped and anything older
# is reached through TYPE_LABEL.
REMOTE_LIMIT="${FRANKLY_REMOTE_LIMIT:-25}"

build_branch_items() {
  BRANCH_ITEMS=()
  local cur seen='' ref note

  cur=$(studio_current_branch)

  # Recents first -- demoing the same two or three branches is the norm.
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    studio_git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || continue
    case " $seen " in *" $ref "*) continue ;; esac
    seen="$seen $ref"
    note='recent'
    [ -d "$(worktree_path "$ref")" ] && note='recent, ready'
    [ "$ref" = "$cur" ] && note="$note, open in Studio"
    BRANCH_ITEMS[${#BRANCH_ITEMS[@]}]="$ref  ·  $note"
  done <<EOF
$(recent_refs)
EOF

  # Then every local branch.
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case " $seen " in *" $ref "*) continue ;; esac
    seen="$seen $ref"
    note='local'
    [ -d "$(worktree_path "$ref")" ] && note='ready'
    [ "$ref" = "$cur" ] && note="$note, open in Studio"
    BRANCH_ITEMS[${#BRANCH_ITEMS[@]}]="$ref  ·  $note"
  done <<EOF
$(studio_git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads 2>/dev/null)
EOF

  # Then the most recently updated remote-only branches. Picking one just
  # creates a worktree at the remote tip -- no local branch is created and
  # nothing in Studio changes.
  local shown=0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    # for-each-ref on refs/remotes/origin also yields the bare "origin"
    # (that is origin/HEAD's short name). Neither is a branch.
    case "$ref" in origin|origin/HEAD) continue ;; esac
    case " $seen " in *" ${ref#origin/} "*) continue ;; esac
    [ "$shown" -ge "$REMOTE_LIMIT" ] && break
    shown=$((shown + 1))
    BRANCH_ITEMS[${#BRANCH_ITEMS[@]}]="$ref  ·  remote"
  done <<EOF
$(studio_git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
EOF

  BRANCH_ITEMS[${#BRANCH_ITEMS[@]}]="$TYPE_LABEL"
  BRANCH_ITEMS[${#BRANCH_ITEMS[@]}]="$FETCH_LABEL"
}

# A one-line text prompt. Prints the answer; returns 1 on cancel.
gui_prompt() {
  local answer
  answer=$(osascript 2>/dev/null \
    -e 'tell me to activate' \
    -e "text returned of (display dialog \"$(as_quote "$1")\" default answer \"$(as_quote "${2:-}")\" with title \"$(as_quote "$APP_NAME")\")") || return 1
  [ -n "$answer" ] || return 1
  printf '%s\n' "$answer"
}

# Accepts "foo", "origin/foo", or a sha. Prints the ref that resolves.
resolve_typed_ref() {
  local want="$1" candidate
  for candidate in "$want" "origin/$want"; do
    if studio_git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Fallback picker: the stock list, used only when the window cannot run.
# Sets PICKED_REF. Returns 1 if the user cancelled.
pick_branch_list() {
  PICKED_REF=''
  while :; do
    build_branch_items
    local picked
    picked=$(choose "Which branch?" single "Choose" "${BRANCH_ITEMS[@]}") || return 1
    if [ "$picked" = "$TYPE_LABEL" ]; then
      local typed resolved
      typed=$(gui_prompt "Branch name (local, or origin/<name>):") || return 1
      if ! resolved=$(resolve_typed_ref "$typed"); then
        gui_alert "$APP_NAME" "No branch or commit called \"$typed\" in $STUDIO.

If it only exists on the remote, refresh the list from origin first."
        continue
      fi
      PICKED_REF="$resolved"
      return 0
    fi
    if [ "$picked" = "$FETCH_LABEL" ]; then
      # The only write this launcher makes in $STUDIO, and only when asked:
      # `fetch` updates remote-tracking refs. It never touches the working
      # tree, the index, or any local branch.
      gui_notify "$APP_NAME" "Fetching from origin..."
      studio_git fetch --quiet --prune origin 2>/dev/null \
        || gui_alert "$APP_NAME" "git fetch failed. The list below may be stale."
      continue
    fi
    PICKED_REF="$(label_ref "$picked")"
    [ -n "$PICKED_REF" ] && return 0
    return 1
  done
}

PICKER_JS="$(dirname "$SELF")/picker.js"

# The real picker: a Cocoa window (see picker.js) with a Default section for
# development, your own branches below it, and checkboxes for merged branches
# and everyone else's. Falls back to the stock list if it cannot run, so a
# broken bridge degrades to something usable rather than to nothing.
#
# Sets PICKED_REF. Returns 1 if the user cancelled.
pick_branch() {
  PICKED_REF=''
  local data result action rest ref
  data="$DEMO_ROOT/.branches"
  mkdir -p "$DEMO_ROOT"

  if [ ! -f "$PICKER_JS" ]; then
    pick_branch_list
    return $?
  fi

  while :; do
    collect_branch_data "$data"
    result=$(osascript -l JavaScript "$PICKER_JS" "$data" 2>/dev/null) || {
      # The window failed outright -- degrade rather than dead-end.
      pick_branch_list
      return $?
    }
    action="${result%%|*}"
    rest="${result#*|}"
    ref="${rest%%|*}"
    case "$action" in
      choose)
        [ -n "$ref" ] || return 1
        PICKED_REF="$ref"
        return 0
        ;;
      fetch)
        # The only write this launcher makes in $STUDIO, and only when asked.
        # It also refreshes what counts as merged, which is measured against
        # the origin/development you last fetched.
        gui_notify "$APP_NAME" "Fetching from origin..."
        studio_git fetch --quiet --prune origin 2>/dev/null || true
        continue
        ;;
      *) return 1 ;;
    esac
  done
}

# Sets PICKED_TARGET to web|admin|both. The api is not optional -- web and
# admin are useless without it -- so it is never offered as a choice.
#
# Three options is what buttons are for. A list would be the wrong control and
# would look like a list of files rather than a question.
pick_target() {
  PICKED_TARGET=''
  local picked
  picked=$(osascript 2>/dev/null \
    -e 'tell me to activate' \
    -e "button returned of (display dialog \"$(as_quote "$1")

Web is the customer app, Admin is the staff app. The api starts either way.\" buttons {\"Web\", \"Admin\", \"Both\"} default button \"Web\" with title \"$(as_quote "$APP_NAME")\"$(icon_clause))") || return 1
  case "$picked" in
    Web)   PICKED_TARGET=web ;;
    Admin) PICKED_TARGET=admin ;;
    Both)  PICKED_TARGET=both ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Cleanup. Worktrees accumulate and each carries its own node_modules.
# ---------------------------------------------------------------------------

cleanup_worktrees() {
  local dir name size items=() picked running_wt=''
  demo_running && running_wt="$S_WORKTREE"

  for dir in "$DEMO_ROOT"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    case "$name" in meta|logs|.*) continue ;; esac
    size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    if [ "$dir" = "$running_wt" ]; then
      items[${#items[@]}]="$name  ·  $size, running - stop it first"
    else
      items[${#items[@]}]="$name  ·  $size"
    fi
  done

  if [ ${#items[@]} -eq 0 ]; then
    if [ "$HAVE_TTY" = 1 ]; then info "No worktrees to remove."
    else gui_alert "$APP_NAME" "There are no demo worktrees to remove."; fi
    return 0
  fi

  picked=$(choose "Remove which worktrees?" multiple "Remove" "${items[@]}") || return 0

  local line label path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    label="$(label_ref "$line")"
    path="$DEMO_ROOT/$label"
    if [ "$path" = "$running_wt" ]; then
      gui_alert "$APP_NAME" "Skipped $label -- its demo is still running. Stop it first."
      continue
    fi
    # `worktree remove` runs in $STUDIO but is a .git metadata operation: it
    # deletes the worktree directory and its administrative entry, and never
    # touches Studio's own working tree.
    studio_git worktree remove --force "$path" >/dev/null 2>&1 || {
      safe_rm_worktree "$path"
      studio_git worktree prune >/dev/null 2>&1
    }
    rm -f "$DEMO_ROOT/meta/$label.ref"
    [ "$HAVE_TTY" = 1 ] && ok "removed $label"
  done <<EOF
$picked
EOF
  studio_git worktree prune >/dev/null 2>&1
  gui_notify "$APP_NAME" "Worktrees removed."
}

# ---------------------------------------------------------------------------
# Running the noisy phase where the user can see it
# ---------------------------------------------------------------------------

# Launched from the Dock there is no terminal, and prepare/install/migrate take
# minutes. Hand that phase to Terminal.app so real output is visible instead of
# a spinner that looks like a hang.
run_in_terminal() {
  local ref="$1" target="$2" cmd
  case "$ref$target" in *\'*) die "Refusing a ref containing a single quote: $ref" "Rename the branch." ;; esac
  cmd="clear; FRANKLY_IN_TERMINAL=1 '$SELF' run '$ref' '$target'"
  osascript >/dev/null 2>&1 \
    -e 'tell application "Terminal"' \
    -e "do script \"$(as_quote "$cmd")\"" \
    -e 'activate' \
    -e 'end tell' \
    || die "Could not open Terminal.app to run the demo." "$cmd"
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

start_flow() {
  pick_branch || return 0
  pick_target "Run $PICKED_REF" || return 0
  remember_ref "$PICKED_REF"
  if [ "$HAVE_TTY" = 1 ]; then
    do_run "$PICKED_REF" "$PICKED_TARGET"
  else
    run_in_terminal "$PICKED_REF" "$PICKED_TARGET"
  fi
}

# How many throwaway worktrees exist, and what they cost. Sets WT_COUNT/WT_SIZE.
worktree_stats() {
  WT_COUNT=0
  WT_SIZE=''
  local dir
  for dir in "$DEMO_ROOT"/*; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in meta|logs|.*) continue ;; esac
    WT_COUNT=$((WT_COUNT + 1))
  done
  [ "$WT_COUNT" -gt 0 ] && WT_SIZE=$(du -sh "$DEMO_ROOT" 2>/dev/null | awk '{print $1}')
}

# "Offer to remove a worktree when done" -- so it is offered when the demo
# stops, which is when it is actually relevant, rather than sitting in the way
# as a permanent menu item every time you just want to start something.
offer_cleanup() {
  worktree_stats
  [ "$WT_COUNT" -gt 0 ] || return 0
  local noun='worktree'
  [ "$WT_COUNT" -gt 1 ] && noun='worktrees'
  ask "Demo stopped.

$WT_COUNT demo $noun using $WT_SIZE. Remove any?" 1 || return 0
  cleanup_worktrees
}

# The running demo, as one native dialog rather than a list of commands.
# Three actions is what buttons are for, and Open is the default so Return
# does the obvious thing.
running_menu() {
  local what urls='' picked
  case "$S_TARGET" in
    web)   what='Web' ;;
    admin) what='Admin' ;;
    both)  what='Web and Admin' ;;
    *)     what="$S_TARGET" ;;
  esac
  alive "$S_WEB_PID"   && urls="localhost:$PORT_WEB"
  alive "$S_ADMIN_PID" && urls="${urls:+$urls    }localhost:$PORT_ADMIN"

  # Built here rather than inline so an absent url line leaves no blank row.
  local body="$S_REF

$what, running since ${S_STARTED#* }"
  [ -n "$urls" ] && body="$body
$urls"

  picked=$(osascript 2>/dev/null \
    -e 'tell me to activate' \
    -e "button returned of (display dialog \"$(as_quote "$body")\" buttons {\"Stop\", \"Switch\", \"Open\"} default button \"Open\" with title \"$(as_quote "$APP_NAME")\"$(icon_clause))") || return 0

  case "$picked" in
    Open)
      alive "$S_WEB_PID"   && open "$URL_WEB"   >/dev/null 2>&1
      alive "$S_ADMIN_PID" && open "$URL_ADMIN" >/dev/null 2>&1
      ;;
    Switch)
      stop_demo quiet
      start_flow
      ;;
    Stop)
      stop_demo quiet
      gui_notify "$APP_NAME" "Demo stopped."
      offer_cleanup
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The run phase, end to end
# ---------------------------------------------------------------------------

do_run() {
  local ref="$1" target="$2"
  case "$target" in web|admin|both) ;; *) die "Unknown target \"$target\"." "$SELF run '$ref' web|admin|both" ;; esac

  printf '%s%s — %s (%s)%s\n' "$C_BLD" "$APP_NAME" "$ref" "$target" "$C_OFF"

  preflight_host

  # One demo at a time, and this is not negotiable: Postgres is shared and
  # cannot be isolated per worktree without more machinery than this deserves.
  # Two dev servers plus a test run on one database is a real deadlock, not a
  # theoretical one.
  if demo_running; then
    warn "A demo is already running: $S_REF ($S_TARGET)."
    dim  "Only one at a time -- they would share the same Postgres."
    ask "Stop it and start this one?" || die "Left the running demo alone." "$SELF stop"
    stop_demo
  fi

  ensure_ports_free "$target"
  prepare_worktree "$ref"
  install_deps    "$WORKTREE"
  bring_up_infra  "$WORKTREE"
  handle_migrations "$WORKTREE"
  start_demo "$WORKTREE" "$ref" "$target"
  remember_ref "$ref"

  printf '\n    %sStop it with:%s  %s stop   (or the Dock icon)\n' "$C_DIM" "$C_OFF" "$SELF"
  printf '    %sThis window can be closed; the demo keeps running.%s\n\n' "$C_DIM" "$C_OFF"
  hold_terminal_open
}

usage() {
  cat <<USAGE
$APP_NAME — run the Frankly demo from a throwaway git worktree.

  $(basename "$SELF")                      interactive (native pickers)
  $(basename "$SELF") run <ref> <target>   target: web | admin | both
  $(basename "$SELF") stop                 stop the running demo
  $(basename "$SELF") status               print status; exit 0 if running
  $(basename "$SELF") cleanup              remove throwaway worktrees

Studio checkout : $STUDIO   (read-only; never checked out, never stashed)
Worktrees       : $DEMO_ROOT
Logs            : $LOG_DIR

One demo at a time -- Postgres is shared.
USAGE
}

main() {
  harden_path
  case "${1:-menu}" in
    run)
      [ $# -eq 3 ] || { usage; exit 2; }
      do_run "$2" "$3"
      ;;
    stop)    stop_demo ;;
    status)  print_status ;;
    cleanup) preflight_host; cleanup_worktrees ;;
    menu|'')
      preflight_host
      # Opening the app means "start a demo" -- there is no menu in the way.
      # A demo already running is the one case where a choice is needed.
      if demo_running; then running_menu; else start_flow; fi
      ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
