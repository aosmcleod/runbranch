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
# This script is the ENGINE. It has no UI of its own beyond a plain terminal
# picker: the front end is "Frankly Launcher.app" (app/FranklyLauncher.swift),
# which runs this as a subprocess and streams its output into a window. Every
# message here is therefore written to be read by a person either way.
#
# Usage:
#   frankly-launcher.sh                      interactive (native pickers)
#   frankly-launcher.sh run <ref> <target>   prepare + start (web|admin|both)
#   frankly-launcher.sh stop                 stop the running demo
#   frankly-launcher.sh status               print status; exit 0 if running
#   frankly-launcher.sh cleanup              remove throwaway worktrees
#
# Written for bash 3.2 (what macOS ships at /bin/bash): no associative arrays,
# no mapfile, no ${var,,}, and no here-documents inside $( ).

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

# Fail loudly. $1 is what went wrong, $2 (optional) is the command that fixes
# it. Both go to the terminal -- and when the app is the caller, "the terminal"
# is the pipe it is streaming into its own window, so the user sees this either
# way. There are deliberately no dialogs left in this script: it is the engine,
# and the app is the only thing that draws.
die() {
  local msg="$1" fix="${2:-}"
  printf '\n%s%s FAILED %s %s\n' "$C_BLD" "$C_RED" "$C_OFF" "$msg" >&2
  if [ -n "$fix" ]; then
    printf '\n%sFix:%s\n\n    %s\n\n' "$C_BLD" "$C_OFF" "$fix" >&2
  fi
  exit 1
}

# A yes/no question. Interactively it prompts. Non-interactively -- which is
# how the app runs it -- there is nobody to answer, so it takes the safe
# default and SAYS SO rather than hanging on a read that never returns.
ask() {
  local question="$1" default_no="${2:-0}" reply hint
  if [ "$HAVE_TTY" != 1 ]; then
    if [ "$default_no" = 1 ]; then
      info "$question  -> no (nothing is listening; assuming the cautious answer)"
      return 1
    fi
    info "$question  -> yes"
    return 0
  fi
  hint='[Y/n]'; [ "$default_no" = 1 ] && hint='[y/N]'
  printf '\n    %s %s ' "$question" "$hint"
  read -r reply || reply=''
  case "$reply" in
    [yY]*) return 0 ;;
    [nN]*) return 1 ;;
    '')    [ "$default_no" = 1 ] && return 1 || return 0 ;;
    *)     return 1 ;;
  esac
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
# Local branches only. The remote carries 636 of them and none of it is work
# anyone here wants to demo.
#
# Merged state has to come from GitHub. git alone is not enough: this repo
# merges some PRs with merge commits and squashes others, and a squashed
# branch's commits are rewritten, so `git branch --merged` never names it --
# verified against docs/commit-name-the-ticket, merged on GitHub and invisible
# to git. So the PR map is cached on disk, read instantly, and refreshed in the
# background. Only the very first launch waits for the network.
# ---------------------------------------------------------------------------

MY_EMAILS="${FRANKLY_MY_EMAILS:-alecmcleod@icloud.com alec.mcleod@functionpoint.com alec@mcleod.co}"
DEFAULT_BRANCH="${FRANKLY_DEFAULT_BRANCH:-development}"
PR_CACHE="$DEMO_ROOT/.prcache"
PR_CACHE_TTL="${FRANKLY_PR_TTL:-900}"   # 15 minutes

# branch <TAB> state, for every PR in the repo.
refresh_pr_cache() {
  command -v gh >/dev/null 2>&1 || return 1
  local tmp="$PR_CACHE.$$"
  mkdir -p "$DEMO_ROOT"
  if gh -R "$(studio_git config --get remote.origin.url 2>/dev/null | sed -e 's#.*github.com[:/]##' -e 's#\.git$##')" \
       pr list --state all --limit 300 --json headRefName,state \
       --jq '.[] | [.headRefName, .state] | @tsv' >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$PR_CACHE"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Instant when a cache exists; refreshes behind your back when it is stale.
ensure_pr_cache() {
  if [ ! -s "$PR_CACHE" ]; then
    refresh_pr_cache || true
    return
  fi
  local age now mtime
  now=$(date +%s)
  mtime=$(stat -f %m "$PR_CACHE" 2>/dev/null || echo 0)
  age=$((now - mtime))
  if [ "$age" -gt "$PR_CACHE_TTL" ]; then
    ( refresh_pr_cache >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
}

# Tab-separated, one local branch per line:
#   ref  age  ts  owner  mine  pr  ready  isDefault  isCurrent
# pr is MERGED / OPEN / CLOSED / NONE.
collect_branch_data() {
  local out="$1" now ready_slugs dir current
  now=$(date +%s)
  current=$(studio_current_branch)
  ensure_pr_cache

  ready_slugs=' '
  for dir in "$DEMO_ROOT"/*; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in meta|logs|.*) continue ;; esac
    ready_slugs="$ready_slugs$(basename "$dir") "
  done

  {
    [ -s "$PR_CACHE" ] && sed 's/^/P\t/' "$PR_CACHE"
    # %09 is a tab. git for-each-ref does NOT interpret \t -- it emits the two
    # characters literally, which silently produces one giant field.
    studio_git for-each-ref --sort=-committerdate \
      --format="B%09%(refname:short)%09%(authoremail)%09%(committerdate:unix)%09%(authorname)" \
      refs/heads 2>/dev/null
  } | awk -F'\t' -v OFS='\t' \
        -v now="$now" -v emails="$MY_EMAILS" -v ready="$ready_slugs" \
        -v current="$current" -v defbr="$DEFAULT_BRANCH" '
    function age(ts,   d) {
      d = now - ts
      if (d < 3600)    return int(d / 60) "m"
      if (d < 86400)   return int(d / 3600) "h"
      if (d < 2592000) return int(d / 86400) "d"
      return int(d / 2592000) "mo"
    }
    function slug(r) { gsub(/[^A-Za-z0-9._-]/, "-", r); return r }
    function mine(email,   i, n, parts) {
      n = split(emails, parts, " ")
      for (i = 1; i <= n; i++) if (index(email, parts[i]) > 0) return 1
      return 0
    }
    # "Matt Disalov" -> "Matt". Keeps the owner badge to one word.
    function firstname(who,   p) { split(who, p, " "); return p[1] }
    $1 == "P" { pr[$2] = $3; next }
    $1 == "B" {
      ref = $2; email = $3; ts = $4; who = $5
      isMine = mine(email)
      state = (ref in pr) ? pr[ref] : "NONE"
      print ref, age(ts), ts, (isMine ? "me" : firstname(who)), isMine, state, \
            (index(ready, " " slug(ref) " ") > 0 ? 1 : 0), \
            (ref == defbr ? 1 : 0), (ref == current ? 1 : 0)
    }
  ' > "$out"
}

# ---------------------------------------------------------------------------
# Terminal picker
#
# The app is the real front end. This exists so `./frankly-launcher.sh` is
# usable on its own -- during development, over ssh, or if the app will not
# build. Same filtering rules as the app: local branches, nothing merged,
# nothing older than a week, unless you ask.
# ---------------------------------------------------------------------------

WEEK=604800

# Sets PICKED_REF. Returns 1 on cancel.
pick_branch() {
  PICKED_REF=''
  local data now i=0 line ref age owner pr ready isdef ts reply
  data="$DEMO_ROOT/.branches"
  mkdir -p "$DEMO_ROOT"
  collect_branch_data "$data"
  now=$(date +%s)

  PICK_REFS=()
  printf '\n%sBranches%s\n\n' "$C_BLD" "$C_OFF"
  while IFS="$(printf '\t')" read -r ref age ts owner _mine pr ready isdef _cur; do
    [ -n "$ref" ] || continue
    if [ "$isdef" != 1 ]; then
      [ "$pr" = MERGED ] && continue
      [ $((now - ts)) -gt "$WEEK" ] && continue
    fi
    i=$((i + 1))
    PICK_REFS[$i]="$ref"
    local tags=''
    # No PR badge on the default branch -- every PR merges INTO development, so
    # its own "merged" state says nothing about the branch you are picking.
    [ "$isdef" = 1 ] && tags="$tags [default]"
    [ "$isdef" != 1 ] && [ "$pr" != NONE ] && tags="$tags [$(printf '%s' "$pr" | tr 'A-Z' 'a-z')]"
    tags="$tags [$owner]"
    [ "$ready" = 1 ]   && tags="$tags [ready]"
    printf '  %2d.  %-38s%s%s%s  %s%s%s\n' "$i" "$ref" \
      "$C_DIM" "$tags" "$C_OFF" "$C_DIM" "$age" "$C_OFF"
  done <"$data"

  [ "$i" -gt 0 ] || die "No branches to show." "$SELF branches   # to see the raw list"

  printf '\n  Number to run, or Return to cancel: '
  read -r reply || reply=''
  case "$reply" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$reply" -ge 1 ] && [ "$reply" -le "$i" ] || return 1
  PICKED_REF="${PICK_REFS[$reply]}"
}

# Sets PICKED_TARGET to web|admin|both.
pick_target() {
  PICKED_TARGET=''
  local reply
  printf '\n  What should run? %s1%s web  %s2%s admin  %s3%s both  [1]: ' \
    "$C_BLD" "$C_OFF" "$C_BLD" "$C_OFF" "$C_BLD" "$C_OFF"
  read -r reply || reply=''
  case "${reply:-1}" in
    1|w|web)   PICKED_TARGET=web ;;
    2|a|admin) PICKED_TARGET=admin ;;
    3|b|both)  PICKED_TARGET=both ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Cleanup. Worktrees accumulate and each carries its own node_modules.
# ---------------------------------------------------------------------------

cleanup_worktrees() {
  local dir name size running_wt='' i=0 reply n
  demo_running && running_wt="$S_WORKTREE"

  CLEAN_PATHS=()
  printf '\n%sDemo worktrees%s\n\n' "$C_BLD" "$C_OFF"
  for dir in "$DEMO_ROOT"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    case "$name" in meta|logs|.*) continue ;; esac
    size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    i=$((i + 1))
    CLEAN_PATHS[$i]="$dir"
    if [ "$dir" = "$running_wt" ]; then
      printf '  %2d.  %-34s %6s  %s(running -- stop it first)%s\n' "$i" "$name" "$size" "$C_YEL" "$C_OFF"
    else
      printf '  %2d.  %-34s %6s\n' "$i" "$name" "$size"
    fi
  done

  if [ "$i" -eq 0 ]; then
    info "No worktrees to remove."
    return 0
  fi

  printf '\n  Numbers to remove (space separated), or Return to cancel: '
  read -r reply || reply=''
  [ -n "$reply" ] || return 0

  for n in $reply; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || continue
    dir="${CLEAN_PATHS[$n]}"
    if [ "$dir" = "$running_wt" ]; then
      warn "skipped $(basename "$dir") -- its demo is still running"
      continue
    fi
    # `worktree remove` runs in $STUDIO but is a .git metadata operation: it
    # deletes the worktree directory and its administrative entry, and never
    # touches Studio's own working tree.
    studio_git worktree remove --force "$dir" >/dev/null 2>&1 || {
      safe_rm_worktree "$dir"
      studio_git worktree prune >/dev/null 2>&1
    }
    rm -f "$DEMO_ROOT/meta/$(basename "$dir").ref"
    ok "removed $(basename "$dir")"
  done
  studio_git worktree prune >/dev/null 2>&1
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
}

usage() {
  cat <<USAGE
$APP_NAME — run the Frankly demo from a throwaway git worktree.

  $(basename "$SELF")                      interactive (native pickers)
  $(basename "$SELF") run <ref> <target>   target: web | admin | both
  $(basename "$SELF") branches             machine-readable branch list (used by the app)
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
    branches)
      # Machine-readable branch list for the app front end. See
      # collect_branch_data for the column order.
      preflight_host >/dev/null 2>&1 || true
      collect_branch_data /dev/stdout
      ;;
    refresh-branches)
      refresh_pr_cache && echo "pr cache refreshed" || echo "pr cache refresh failed" >&2
      ;;
    stop)    stop_demo ;;
    status)  print_status ;;
    cleanup) preflight_host; cleanup_worktrees ;;
    menu|'')
      if [ "$HAVE_TTY" != 1 ]; then
        die "Nothing to show: this is the engine, not the front end." \
          "open '$(dirname "$SELF")/Frankly Launcher.app'"
      fi
      preflight_host
      if demo_running; then
        print_status
        ask "Stop it?" 1 && stop_demo
        exit 0
      fi
      pick_branch || exit 0
      pick_target || exit 0
      remember_ref "$PICKED_REF"
      do_run "$PICKED_REF" "$PICKED_TARGET"
      ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
