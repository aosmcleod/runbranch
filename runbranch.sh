#!/usr/bin/env bash
#
# Runbranch — run any local project from a throwaway git worktree.
#
# The problem, which is not specific to one repo: demoing out of your working
# checkout means the demo competes with whatever you are editing. Switching
# branches to show something either fails on uncommitted work or silently
# changes what the person at the keyboard is looking at. And gitignored config
# (.env.local and friends) does not exist in a fresh tree, so everything 401s
# or cannot reach its database — which reads as a broken branch.
#
# The fix, and the whole idea: one throwaway git worktree per branch. The
# working checkout is NEVER modified. Everything else is ergonomics.
#
#   <your repo>                                  <- never modified
#   ~/.runbranch/<project>/worktrees/<branch>/   <- throwaway
#
# This script is the ENGINE. Its only UI is a plain terminal picker; the front
# end is "runbranch.app" (app/RunBranch.swift), which runs this as
# a subprocess and streams its output into a window. Every message here is
# written to be read by a person either way.
#
# Projects are declared in projects/*.conf — see projects/README.md.
#
# Written for bash 3.2 (what macOS ships at /bin/bash): no associative arrays,
# no mapfile, no ${var,,}, and no here-documents inside $( ).

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"

RB_HOME="${RB_HOME:-$HOME/.runbranch}"
PROJECTS_DIR="${RB_PROJECTS_DIR:-$SELF_DIR/projects}"

# Every address you author commits under. A branch is "yours" when its tip
# carries one of them.
MY_EMAILS="${RB_MY_EMAILS:-alecmcleod@icloud.com alec.mcleod@functionpoint.com alec@mcleod.co}"

PR_CACHE_TTL="${RB_PR_TTL:-900}"   # 15 minutes
WEEK=604800

# ---------------------------------------------------------------------------
# Output
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

# Fail loudly. $2 names the command that fixes it — that is the whole reason
# this tool exists. There are no dialogs here; the app shows what we print.
die() {
  local msg="$1" fix="${2:-}"
  printf '\n%s%s FAILED %s %s\n' "$C_BLD" "$C_RED" "$C_OFF" "$msg" >&2
  [ -n "$fix" ] && printf '\n%sFix:%s\n\n    %s\n\n' "$C_BLD" "$C_OFF" "$fix" >&2
  exit 1
}

# Non-interactively — which is how the app runs it — there is nobody to answer,
# so take the stated default and SAY SO rather than hang on a read.
ask() {
  local question="$1" default_no="${2:-0}" reply hint
  if [ "$HAVE_TTY" != 1 ]; then
    if [ "$default_no" = 1 ]; then
      info "$question  -> no (assuming the cautious answer)"
      return 1
    fi
    info "$question  -> yes"
    return 0
  fi
  hint='[Y/n]'; [ "$default_no" = 1 ] && hint='[y/N]'
  printf '\n    %s %s ' "$question" "$hint"
  read -r reply || reply=''
  case "$reply" in
    [yY]*) return 0 ;; [nN]*) return 1 ;;
    '') [ "$default_no" = 1 ] && return 1 || return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# PATH hardening
#
# An app launched from the Dock inherits launchd's PATH — /usr/bin:/bin:
# /usr/sbin:/sbin — not the one your shell builds. Under it docker
# (/usr/local/bin), pnpm and gh (/opt/homebrew/bin) and node (fnm, whose bin
# directory is minted per shell session) are all invisible, and the launcher
# would report them missing while they sit right there.
#
# The app runs this script through `zsh -lic` so PATH matches your terminal.
# This is the second layer, for when it is invoked with a bare environment.
# ---------------------------------------------------------------------------

harden_path() {
  local dir
  for dir in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin \
             "$HOME/.local/bin" "$HOME/Library/pnpm" \
             /Applications/Docker.app/Contents/Resources/bin; do
    [ -d "$dir" ] || continue
    case ":$PATH:" in *":$dir:"*) ;; *) PATH="$PATH:$dir" ;; esac
  done
  export PATH
  if ! command -v node >/dev/null 2>&1 && command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env 2>/dev/null)" || true
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  die "\`$1\` is not on PATH.

The launcher already looks in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin,
~/Library/pnpm, Docker.app's bundled bin, and asks fnm for its node directory.
So $1 is either genuinely missing, or installed somewhere unusual." "$2"
}

# ---------------------------------------------------------------------------
# Projects
#
# A project is a small bash file in projects/. Keys are documented in
# projects/README.md. Everything except NAME, REPO and TARGETS is optional,
# which is the point: most projects are "install, run one command, open a
# URL", and only pay for the machinery they actually use.
# ---------------------------------------------------------------------------

PROJECT=''

load_project() {
  # Split deliberately: bash expands every argument to `local` BEFORE it
  # assigns any of them, so $name in the same statement reads the unset global.
  local name="$1"
  local file="$PROJECTS_DIR/$name.conf"
  [ -f "$file" ] || die "No project called \"$name\"." \
    "ls $PROJECTS_DIR    # or add $name.conf there"

  # Defaults, reset on every load so a second load cannot inherit the first.
  NAME=""; REPO=""; DEFAULT_BRANCH="main"; INSTALL=""; COPY_FILES=""
  COMPOSE_FILE="docker-compose.yml"; COMPOSE_PROJECT=""; COMPOSE_SERVICES=""
  MIGRATE=""; TARGETS=""; ALWAYS=""; PRESETS=""; OPENS_ITSELF=0; SYMBOL=""

  # shellcheck disable=SC1090
  . "$file"

  PROJECT="$name"
  [ -n "$NAME" ] || NAME="$name"
  [ -n "$REPO" ] || die "$name.conf sets no REPO." "edit $file"
  case "$REPO" in "~"*) REPO="$HOME${REPO#\~}" ;; esac
  [ -d "$REPO/.git" ] || die "$NAME: $REPO is not a git repository." "edit $file"
  [ -n "$TARGETS" ] || die "$name.conf declares no TARGETS." "edit $file"

  WORK_ROOT="$RB_HOME/$name"
  WORKTREES="$WORK_ROOT/worktrees"
  LOG_DIR="$WORK_ROOT/logs"
  STATE_FILE="$WORK_ROOT/state"
  PR_CACHE="$WORK_ROOT/prcache"
  META_DIR="$WORK_ROOT/meta"
}

list_projects() {
  local f name
  [ -d "$PROJECTS_DIR" ] || return 0
  for f in "$PROJECTS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .conf)"
    ( load_project "$name" >/dev/null 2>&1 || exit 0
      [ -n "$PROJECT" ] || exit 0
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$NAME" "$REPO" \
        "$( [ -f "$STATE_FILE" ] && echo 1 || echo 0 )" "${SYMBOL:-shippingbox}" )
  done
}

# --- target parsing ---------------------------------------------------------
# TARGETS is one per line: name:port:healthpath:command
# The command may contain colons, so only the first three are separators.

target_field() {
  local want="$1" field="$2" line n
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    n="${line%%:*}"
    [ "$n" = "$want" ] || continue
    local rest="${line#*:}"
    case "$field" in
      port)    printf '%s' "${rest%%:*}" ;;
      health)  rest="${rest#*:}"; printf '%s' "${rest%%:*}" ;;
      command) rest="${rest#*:}"; rest="${rest#*:}"; printf '%s' "$rest" ;;
    esac
    return 0
  done <<EOF
$TARGETS
EOF
  return 1
}

target_names() {
  local line
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    printf '%s\n' "${line%%:*}"
  done <<EOF
$TARGETS
EOF
}

# Presets are named combinations: "web=api,web  both=api,web,admin".
# With none declared, each target is its own preset, plus "all" when there is
# more than one — so a single-server project needs no PRESETS line at all.
preset_names() {
  local p
  if [ -n "$PRESETS" ]; then
    for p in $PRESETS; do printf '%s\n' "${p%%=*}"; done
    return
  fi
  target_names
  [ "$(target_names | wc -l | tr -d ' ')" -gt 1 ] && printf 'all\n'
  return 0
}

# The target list a preset expands to, always with ALWAYS targets first.
preset_targets() {
  local want="$1" p out='' t
  if [ -n "$PRESETS" ]; then
    for p in $PRESETS; do
      [ "${p%%=*}" = "$want" ] || continue
      out="$(printf '%s' "${p#*=}" | tr ',' ' ')"
      break
    done
  fi
  if [ -z "$out" ]; then
    if [ "$want" = all ]; then out="$(target_names | tr '\n' ' ')"; else out="$want"; fi
  fi
  local final=''
  for t in $ALWAYS; do
    case " $out " in *" $t "*) ;; *) final="$final $t" ;; esac
  done
  printf '%s' "$(printf '%s %s' "$final" "$out" | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')"
}

# ---------------------------------------------------------------------------
# Git, worktrees, branch data
# ---------------------------------------------------------------------------

# The ONLY things done in your checkout: read refs, copy gitignored files, and
# git-worktree metadata operations. No checkout, no stash. `fetch` only when
# you explicitly ask for it.
repo_git() { git -C "$REPO" "$@"; }

current_branch() { repo_git rev-parse --abbrev-ref HEAD 2>/dev/null; }
slug_for() { printf '%s' "$1" | sed -e 's#^origin/##' -e 's#[^A-Za-z0-9._-]#-#g'; }
worktree_path() { printf '%s/%s' "$WORKTREES" "$(slug_for "$1")"; }

# owner/repo, for gh. Empty when there is no GitHub remote, in which case PR
# badges are simply absent rather than an error.
gh_repo() {
  repo_git config --get remote.origin.url 2>/dev/null \
    | sed -e 's#.*github\.com[:/]##' -e 's#\.git$##' | grep '/' || true
}

refresh_pr_cache() {
  command -v gh >/dev/null 2>&1 || return 1
  local slug tmp
  slug="$(gh_repo)"
  [ -n "$slug" ] || return 1
  mkdir -p "$WORK_ROOT"
  tmp="$PR_CACHE.$$"
  # Title and number too: a branch name says what someone called the work,
  # the PR title says what it is.
  if gh -R "$slug" pr list --state all --limit 300 \
       --json headRefName,state,number,title,author \
       --jq '.[] | [.headRefName, .state, (.number|tostring), .title, .author.login] | @tsv' \
       >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$PR_CACHE"; return 0
  fi
  rm -f "$tmp"; return 1
}

# Instant when a cache exists; refreshes behind your back when it is stale.
#
# Why GitHub at all: `git branch --merged` looks like it should answer this for
# free, and for a merge-commit PR it does. But a SQUASHED merge rewrites the
# commits, so they are never reachable from the default branch and git can
# never name it. Verified the hard way on Studio.
ensure_pr_cache() {
  if [ ! -s "$PR_CACHE" ]; then refresh_pr_cache || true; return; fi
  local mtime age
  mtime=$(stat -f %m "$PR_CACHE" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - mtime ))
  [ "$age" -gt "$PR_CACHE_TTL" ] && ( refresh_pr_cache >/dev/null 2>&1 & ) >/dev/null 2>&1
  return 0
}

# Tab separated, one branch per line:
#   ref  age  ts  owner  mine  pr  ready  isDefault  isCurrent  prNumber  subject  remote
#
# Local branches first, then remote-tracking branches with no local twin —
# reviewing a colleague's pull request is the whole use case, and it does not
# start with a local branch.
collect_branch_data() {
  local out="$1" now ready_slugs dir cur
  now=$(date +%s)
  cur=$(current_branch)
  ensure_pr_cache

  ready_slugs=' '
  if [ -d "$WORKTREES" ]; then
    for dir in "$WORKTREES"/*; do
      [ -d "$dir" ] || continue
      ready_slugs="$ready_slugs$(basename "$dir") "
    done
  fi

  {
    [ -s "$PR_CACHE" ] && sed 's/^/P\'$'\t''/' "$PR_CACHE"
    # %09 is a tab. git for-each-ref does NOT interpret \t — it emits the two
    # characters literally, which silently collapses every row into one field.
    repo_git for-each-ref --sort=-committerdate \
      --format="B%09%(refname:short)%09%(authoremail)%09%(committerdate:unix)%09%(authorname)%09%(contents:subject)" \
      refs/heads 2>/dev/null
    repo_git for-each-ref --sort=-committerdate \
      --format="R%09%(refname:short)%09%(authoremail)%09%(committerdate:unix)%09%(authorname)%09%(contents:subject)" \
      refs/remotes/origin 2>/dev/null
  } | awk -F'\t' -v OFS='\t' \
        -v now="$now" -v emails="$MY_EMAILS" -v ready="$ready_slugs" \
        -v cur="$cur" -v defbr="$DEFAULT_BRANCH" '
    function age(ts,   d) {
      d = now - ts
      if (d < 3600)    return int(d / 60) "m"
      if (d < 86400)   return int(d / 3600) "h"
      if (d < 2592000) return int(d / 86400) "d"
      return int(d / 2592000) "mo"
    }
    function slug(r) { gsub(/[^A-Za-z0-9._-]/, "-", r); return r }
    function mine(e,   i, n, p) {
      n = split(emails, p, " ")
      for (i = 1; i <= n; i++) if (index(e, p[i]) > 0) return 1
      return 0
    }
    function firstname(w,   p) { split(w, p, " "); return p[1] }
    $1 == "P" { pr[$2] = $3; num[$2] = $4; title[$2] = $5; next }
    function emit(ref, key, email, ts, who, subject, isRemote,   isMine) {
      isMine = mine(email)
      print ref, age(ts), ts, (isMine ? "me" : firstname(who)), isMine, \
            ((key in pr) ? pr[key] : "NONE"), \
            (index(ready, " " slug(ref) " ") > 0 ? 1 : 0), \
            (ref == defbr ? 1 : 0), (ref == cur ? 1 : 0), \
            ((key in num) ? num[key] : ""), \
            ((key in title) ? title[key] : subject), \
            isRemote
    }
    $1 == "B" { seen[$2] = 1; emit($2, $2, $3, $4, $5, $6, 0); next }
    $1 == "R" {
      short = $2; sub(/^origin\//, "", short)
      if (short == "" || $2 == "origin" || $2 == "origin/HEAD") next
      if (seen[short]) next          # a local branch already stands for it
      emit($2, short, $3, $4, $5, $6, 1)
    }
  ' > "$out"
}

# Worktrees are created DETACHED at the branch tip, never as a checkout of the
# branch. Git refuses to check out a branch already checked out elsewhere —
# and demoing the branch you are working on is the common case. A demo runner
# also has no business holding a ref it might move.
WORKTREE=''
prepare_worktree() {
  local ref="$1" wt tip at f
  wt="$(worktree_path "$ref")"
  tip=$(repo_git rev-parse --verify --quiet "$ref^{commit}")
  [ -n "$tip" ] || die "\`$ref\` does not resolve to a commit in $REPO." \
    "cd $REPO && git fetch origin"

  step "Worktree  $wt"
  mkdir -p "$WORKTREES" "$META_DIR" "$LOG_DIR"

  if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
    at=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [ "$at" = "$tip" ]; then
      ok "already at $(printf '%.9s' "$tip")"
    else
      info "updating $(printf '%.9s' "$at") -> $(printf '%.9s' "$tip")"
      git -C "$wt" checkout --detach --force "$tip" >/dev/null 2>&1 || die \
        "Could not move the worktree to $ref." \
        "$SELF remove-worktree $PROJECT '$ref'"
      ok "moved to $(printf '%.9s' "$tip")"
    fi
  else
    repo_git worktree prune >/dev/null 2>&1
    safe_rm_worktree "$wt"
    info "creating worktree (detached at $(printf '%.9s' "$tip"))"
    repo_git worktree add --detach "$wt" "$tip" >/dev/null 2>&1 || die \
      "\`git worktree add\` failed for $ref." \
      "cd $REPO && git worktree add --detach '$wt' '$tip'"
    ok "created"
  fi

  printf '%s\n' "$ref" >"$META_DIR/$(slug_for "$ref").ref"

  # Worktrees do not inherit untracked files, and this config is gitignored.
  # Copy it EVERY time, not just on create: it changes in the main checkout and
  # a stale copy is indistinguishable from a broken branch.
  for f in $COPY_FILES; do
    if [ -e "$REPO/$f" ]; then
      cp -R "$REPO/$f" "$wt/$f"
      ok "$f copied from the main checkout"
    else
      warn "$f is declared in COPY_FILES but missing from $REPO"
    fi
  done

  WORKTREE="$wt"
}

# rm -rf with a leash: refuses anything that is not a direct child of this
# project's worktree root.
safe_rm_worktree() {
  local path="$1" parent
  [ -n "$path" ] || return 1
  [ -e "$path" ] || return 0
  parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd)"
  if [ "$parent" != "$WORKTREES" ] || [ "$path" = "$WORKTREES" ]; then
    die "Refusing to delete $path — it is not a throwaway worktree under $WORKTREES." \
      "Remove it by hand if that is really what you want."
  fi
  rm -rf "$path"
}

remove_worktree_for() {
  local ref="$1" wt
  wt="$(worktree_path "$ref")"
  [ -d "$wt" ] || { info "No worktree for $ref."; return 0; }
  if demo_running && [ "$S_WORKTREE" = "$wt" ]; then
    die "$ref is running, so its worktree is in use." "$SELF stop $PROJECT"
  fi
  step "Removing worktree for $ref"
  repo_git worktree remove --force "$wt" >/dev/null 2>&1 || {
    safe_rm_worktree "$wt"
    repo_git worktree prune >/dev/null 2>&1
  }
  rm -f "$META_DIR/$(slug_for "$ref").ref"
  ok "removed $wt"
}

# ---------------------------------------------------------------------------
# Install, infrastructure, migrations — all optional per project
# ---------------------------------------------------------------------------

GH_PACKAGES_REFRESH='gh auth refresh -h github.com -s read:packages'

install_deps() {
  local wt="$1" log="$LOG_DIR/install.log" rc
  [ -n "$INSTALL" ] || return 0
  step "Dependencies"
  info "$INSTALL   (first run on a branch can take a few minutes)"
  info "logging to $log"
  printf '\n'
  ( cd "$wt" && eval "$INSTALL" 2>&1 ) | tee "$log"
  rc=${PIPESTATUS[0]}
  printf '\n'
  [ "$rc" = 0 ] && { ok "dependencies installed"; return 0; }

  # Turn the failures that actually happen into instructions.
  if grep -qiE 'ERR_PNPM_FETCH_401|401 Unauthorized|npm\.pkg\.github\.com.*(401|Unauthorized)' "$log"; then
    die "The registry returned 401 while installing a private package.

A default \`gh auth login\` does not grant read:packages, which is why this
catches people." "$GH_PACKAGES_REFRESH
    cd $wt && $INSTALL"
  fi
  if grep -qiE 'ERR_PNPM_OUTDATED_LOCKFILE|frozen-lockfile|npm ci.*can only install' "$log"; then
    die "The lockfile on this branch does not match its manifest, so the install
refused. That is a real inconsistency on the branch, not a launcher problem." \
      "cd $wt && ${INSTALL%% *} install     # accept the drift, then re-run"
  fi
  die "Install failed. The last lines are above; the full log is at $log." \
    "cd $wt && $INSTALL"
}

# -p pins the compose project. compose derives its name from the directory it
# runs in, so from a worktree it would create a SECOND project with its own
# empty volumes — and then collide on any fixed container_name.
compose() {
  local wt="$1"; shift
  docker compose -p "$COMPOSE_PROJECT" -f "$wt/$COMPOSE_FILE" "$@"
}

bring_up_infra() {
  local wt="$1"
  [ -n "$COMPOSE_SERVICES" ] || return 0
  require_cmd docker 'Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
  docker info >/dev/null 2>&1 || die \
    "Docker is installed but the daemon is not responding." \
    'open -a Docker    # then wait for the whale icon to settle'
  [ -n "$COMPOSE_PROJECT" ] || COMPOSE_PROJECT="$PROJECT"
  step "Infrastructure  (compose project: $COMPOSE_PROJECT)"
  info "docker compose up -d --wait $COMPOSE_SERVICES"
  # shellcheck disable=SC2086
  compose "$wt" up -d --wait $COMPOSE_SERVICES >/dev/null 2>&1 || die \
    "$COMPOSE_SERVICES did not come up healthy." \
    "docker compose -p $COMPOSE_PROJECT -f $wt/$COMPOSE_FILE logs $COMPOSE_SERVICES"
  ok "$COMPOSE_SERVICES healthy"
}

handle_migrations() {
  local wt="$1"
  [ -n "$MIGRATE" ] || return 0
  step "Database"
  info "$MIGRATE"
  dim "this mutates the shared database — every branch of this project uses it"
  ( cd "$wt" && eval "$MIGRATE" ) || die "Migrations failed." "cd $wt && $MIGRATE"
  ok "migrations applied"
}

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------

port_holder() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1; }
port_holder_desc() { ps -o pid=,command= -p "$1" 2>/dev/null | sed -e 's/^ *//' | cut -c1-110; }

ensure_ports_free() {
  local targets="$1" t port pid busy=''
  for t in $targets; do
    port="$(target_field "$t" port)"
    [ -n "$port" ] || continue
    pid=$(port_holder "$port")
    [ -n "$pid" ] && busy="$busy
  $t on port $port  ->  $(port_holder_desc "$pid")"
  done
  [ -z "$busy" ] && return 0
  die "Something is already listening on a port this needs:
$busy

If that is your own dev server, leave it alone and stop it yourself." \
    "$SELF stop $PROJECT      # a leftover run
    kill <pid>               # your own server, on purpose"
}

# ---------------------------------------------------------------------------
# Servers
#
# Each server starts in its OWN PROCESS GROUP (`set -m` gives a background job
# a fresh pgid equal to its pid). That matters for stopping: a watcher such as
# `tsx --watch` RESPAWNS its child if you kill only the child. Signalling the
# group takes the whole tree down.
# ---------------------------------------------------------------------------

STARTED_PID=''
start_server() {
  local wt="$1" name="$2"
  local cmd log pid
  cmd="$(target_field "$name" command)"
  log="$LOG_DIR/$name.log"
  mkdir -p "$LOG_DIR"
  : >"$log"
  set -m
  ( cd "$wt" && exec nohup /bin/bash -c "$cmd" ) >"$log" 2>&1 &
  pid=$!
  disown %% 2>/dev/null || true
  set +m
  sleep 1
  kill -0 "$pid" 2>/dev/null || {
    printf '\n'; tail -20 "$log"; printf '\n'
    die "$name exited immediately. Its log is above and at $log." "cd $wt && $cmd"
  }
  ok "$name started (pgid $pid) -> $log"
  STARTED_PID="$pid"
}

# Any HTTP status counts: a dev server returning 404 for a route it has not
# compiled yet is still up.
wait_for_http() {
  local url="$1" label="$2" timeout="$3" pid="$4" waited=0 code
  info "waiting for $label at $url"
  while [ "$waited" -lt "$timeout" ]; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then return 2; fi
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" 2>/dev/null)
    if [ -n "$code" ] && [ "$code" != 000 ]; then
      ok "$label responding (HTTP $code after ${waited}s)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
    case "$waited" in 20|60|120) dim "still waiting... (${waited}s; a first compile is slow)" ;; esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# State, start, stop
# ---------------------------------------------------------------------------

write_state() {
  mkdir -p "$WORK_ROOT"
  {
    printf 'REF=%s\n'      "$1"
    printf 'WORKTREE=%s\n' "$2"
    printf 'PRESET=%s\n'   "$3"
    printf 'TARGETS=%s\n'  "$4"
    printf 'PIDS=%s\n'     "$5"
    printf 'STARTED=%s\n'  "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'EPOCH=%s\n'    "$(date +%s)"
  } >"$STATE_FILE"
}

load_state() {
  S_REF=''; S_WORKTREE=''; S_PRESET=''; S_TARGETS=''; S_PIDS=''; S_STARTED=''; S_EPOCH=0
  [ -f "$STATE_FILE" ] || return 1
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      REF) S_REF="$val" ;; WORKTREE) S_WORKTREE="$val" ;;
      PRESET) S_PRESET="$val" ;; TARGETS) S_TARGETS="$val" ;;
      PIDS) S_PIDS="$val" ;; STARTED) S_STARTED="$val" ;; EPOCH) S_EPOCH="$val" ;;
    esac
  done <"$STATE_FILE"
  return 0
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

demo_running() {
  load_state || return 1
  local p
  for p in $S_PIDS; do alive "$p" && return 0; done
  return 1
}

# Every live target's URL, comma separated — what "Open" offers.
running_urls() {
  local t port out=''
  for t in $S_TARGETS; do
    port="$(target_field "$t" port)"
    [ -n "$port" ] && out="$out,http://localhost:$port"
  done
  printf '%s' "${out#,}"
}

start_run() {
  local wt="$1" ref="$2" preset="$3" targets="$4"
  local t pids='' named='' rc url health port first=''

  step "Servers"
  for t in $targets; do
    start_server "$wt" "$t"
    pids="$pids $STARTED_PID"
    named="$named $t:$STARTED_PID"
  done
  write_state "$ref" "$wt" "$preset" "$targets" "$(echo $pids)"

  step "Waiting"
  local i=0
  for t in $targets; do
    i=$((i + 1))
    port="$(target_field "$t" port)"
    health="$(target_field "$t" health)"
    [ -n "$port" ] || continue
    local pid; pid="$(printf '%s' "$named" | tr ' ' '\n' | grep "^$t:" | cut -d: -f2)"
    url="http://localhost:$port${health:-/}"
    wait_for_http "$url" "$t" 240 "$pid"; rc=$?
    if [ "$rc" != 0 ]; then
      printf '\n'; tail -25 "$LOG_DIR/$t.log"; printf '\n'
      local why="$t never answered within the timeout"
      [ "$rc" = 2 ] && why="$t exited while starting"
      stop_run quiet
      die "$why. The last log lines are above; the full log is at $LOG_DIR/$t.log." \
        "cd $wt && $(target_field "$t" command)"
    fi
    [ -z "$first" ] && first="http://localhost:$port"
  done

  step "Ready"
  for t in $targets; do
    port="$(target_field "$t" port)"
    [ -n "$port" ] && info "$(printf '%-8s' "$t") http://localhost:$port"
  done
  # Some dev servers (vite --open) open a browser themselves; opening a second
  # one is just a duplicate tab.
  if [ "$OPENS_ITSELF" != 1 ] && [ -n "$first" ]; then
    open "$first" >/dev/null 2>&1
  fi
}

# Signal the whole process group, not the pid: that is what takes a watcher
# down with its child instead of letting it respawn.
kill_group() {
  local pgid="$1" waited=0
  [ -n "$pgid" ] || return 0
  kill -0 "$pgid" 2>/dev/null || return 0
  kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
  while [ "$waited" -lt 12 ]; do
    kill -0 "$pgid" 2>/dev/null || return 0
    sleep 1; waited=$((waited + 1))
  done
  kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
}

stop_run() {
  local quiet="${1:-}" p t port pid cmd left=''
  if ! load_state; then
    [ "$quiet" = quiet ] || info "Nothing is recorded as running for $NAME."
    return 0
  fi
  [ "$quiet" = quiet ] || step "Stopping  $NAME — $S_REF ($S_PRESET)"
  for p in $S_PIDS; do kill_group "$p"; done
  rm -f "$STATE_FILE"

  # Anything still on one of our ports is a stray. Only reap it when it is
  # clearly ours — a process whose command line points into this project's
  # worktrees. Never touch the user's own dev server.
  for t in $S_TARGETS; do
    port="$(target_field "$t" port)"
    [ -n "$port" ] || continue
    pid=$(port_holder "$port")
    [ -n "$pid" ] || continue
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$cmd" in
      *"$WORKTREES"*) kill -TERM "$pid" 2>/dev/null || true ;;
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

do_run() {
  local ref="$1" preset="$2" targets
  targets="$(preset_targets "$preset")"
  [ -n "$targets" ] || die "Unknown preset \"$preset\" for $NAME." \
    "$SELF presets $PROJECT"

  printf '%s%s — %s (%s)%s\n' "$C_BLD" "$NAME" "$ref" "$preset" "$C_OFF"

  harden_path
  require_cmd git 'xcode-select --install'

  if demo_running; then
    warn "$NAME already has $S_REF running."
    ask "Stop it and start this one?" || die "Left it alone." "$SELF stop $PROJECT"
    stop_run
  fi

  ensure_ports_free "$targets"
  prepare_worktree "$ref"
  install_deps      "$WORKTREE"
  bring_up_infra    "$WORKTREE"
  handle_migrations "$WORKTREE"
  start_run "$WORKTREE" "$ref" "$preset" "$targets"
}

print_status() {
  if demo_running; then
    printf '\n%s%s running%s\n' "$C_BLD" "$NAME" "$C_OFF"
    printf '  branch    %s\n'  "$S_REF"
    printf '  running   %s\n'  "$S_PRESET"
    printf '  worktree  %s\n'  "$S_WORKTREE"
    printf '  since     %s\n'  "$S_STARTED"
    local t port
    for t in $S_TARGETS; do
      port="$(target_field "$t" port)"
      [ -n "$port" ] && printf '  %-9s http://localhost:%s\n' "$t" "$port"
    done
    printf '  logs      %s\n\n' "$LOG_DIR"
    return 0
  fi
  printf '\n%s: nothing running.\n\n' "$NAME"
  return 1
}

# ---------------------------------------------------------------------------
# Reclaiming what a crash left behind
#
# A force quit, a panic or a sleep can leave servers holding ports with no
# state to match, or state naming pids that are long gone. Neither is the
# user's problem to solve with `lsof`, so find both on demand.
# ---------------------------------------------------------------------------

# Anything still listening on one of this project's ports whose command line
# points into its worktrees is ours, whatever the state file believes.
reclaim_project() {
  local t port pid cmd found=0 stale=0
  if load_state && ! demo_running; then
    stale=1
  fi

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    port="$(target_field "$t" port)"
    [ -n "$port" ] || continue
    pid=$(port_holder "$port")
    [ -n "$pid" ] || continue
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$cmd" in
      *"$WORKTREES"*)
        # Ours, and not accounted for by a live run.
        if [ "$stale" = 1 ] || ! demo_running; then
          info "$NAME: reclaiming $t on port $port (pid $pid)"
          kill_group "$pid"
          found=$((found + 1))
        fi
        ;;
    esac
  done <<EOF
$(target_names)
EOF

  if [ "$stale" = 1 ]; then
    info "$NAME: clearing stale state for $S_REF"
    rm -f "$STATE_FILE"
    found=$((found + 1))
  fi
  return "$found"
}

reclaim_all() {
  local n total=0
  while IFS="$(printf '\t')" read -r n _; do
    [ -n "$n" ] || continue
    ( load_project "$n" >/dev/null 2>&1 || exit 0
      reclaim_project || exit $? ) || total=$((total + $?))
  done <<EOF
$(list_projects)
EOF
  [ "$total" = 0 ] && info "Nothing to reclaim."
  return 0
}

# ---------------------------------------------------------------------------
# Terminal picker
#
# The app is the real front end. This exists so the script is usable alone —
# during development, over ssh, or if the app will not build.
# ---------------------------------------------------------------------------

pick_project() {
  PICKED_PROJECT=''
  local i=0 name disp repo has line reply
  PROJ_NAMES=()
  printf '\n%sProjects%s\n\n' "$C_BLD" "$C_OFF"
  while IFS="$(printf '\t')" read -r name disp repo has; do
    [ -n "$name" ] || continue
    i=$((i + 1)); PROJ_NAMES[$i]="$name"
    printf '  %2d.  %-22s %s%s%s\n' "$i" "$disp" "$C_DIM" "$repo" "$C_OFF"
  done <<EOF
$(list_projects)
EOF
  [ "$i" -gt 0 ] || die "No projects declared." "ls $PROJECTS_DIR"
  if [ "$i" = 1 ]; then PICKED_PROJECT="${PROJ_NAMES[1]}"; return 0; fi
  printf '\n  Number, or Return to cancel: '
  read -r reply || reply=''
  case "$reply" in ''|*[!0-9]*) return 1 ;; esac
  [ "$reply" -ge 1 ] && [ "$reply" -le "$i" ] || return 1
  PICKED_PROJECT="${PROJ_NAMES[$reply]}"
}

pick_branch() {
  PICKED_REF=''
  local data now i=0 ref age ts owner mine pr ready isdef cur reply tags
  data="$WORK_ROOT/branches"
  mkdir -p "$WORK_ROOT"
  collect_branch_data "$data"
  now=$(date +%s)

  PICK_REFS=()
  printf '\n%sBranches — %s%s\n\n' "$C_BLD" "$NAME" "$C_OFF"
  while IFS="$(printf '\t')" read -r ref age ts owner mine pr ready isdef cur; do
    [ -n "$ref" ] || continue
    if [ "$isdef" != 1 ]; then
      [ "$pr" = MERGED ] && continue
      [ $((now - ts)) -gt "$WEEK" ] && continue
    fi
    i=$((i + 1)); PICK_REFS[$i]="$ref"
    tags=''
    [ "$isdef" = 1 ] && tags="$tags [default]"
    [ "$isdef" != 1 ] && [ "$pr" != NONE ] && tags="$tags [$(printf '%s' "$pr" | tr 'A-Z' 'a-z')]"
    tags="$tags [$owner]"
    [ "$ready" = 1 ] && tags="$tags [ready]"
    printf '  %2d.  %-36s%s%s%s  %s%s%s\n' "$i" "$ref" "$C_DIM" "$tags" "$C_OFF" "$C_DIM" "$age" "$C_OFF"
  done <"$data"

  [ "$i" -gt 0 ] || die "No branches to show for $NAME." "$SELF branches $PROJECT"
  printf '\n  Number to run, or Return to cancel: '
  read -r reply || reply=''
  case "$reply" in ''|*[!0-9]*) return 1 ;; esac
  [ "$reply" -ge 1 ] && [ "$reply" -le "$i" ] || return 1
  PICKED_REF="${PICK_REFS[$reply]}"
}

pick_preset() {
  PICKED_PRESET=''
  local i=0 p reply
  PRESET_LIST=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    i=$((i + 1)); PRESET_LIST[$i]="$p"
  done <<EOF
$(preset_names)
EOF
  [ "$i" -gt 0 ] || return 1
  if [ "$i" = 1 ]; then PICKED_PRESET="${PRESET_LIST[1]}"; return 0; fi
  printf '\n  What should run? '
  for p in $(seq 1 $i); do printf '%s%s%s %s  ' "$C_BLD" "$p" "$C_OFF" "${PRESET_LIST[$p]}"; done
  printf '[1]: '
  read -r reply || reply=''
  [ -z "$reply" ] && reply=1
  case "$reply" in *[!0-9]*) return 1 ;; esac
  [ "$reply" -ge 1 ] && [ "$reply" -le "$i" ] || return 1
  PICKED_PRESET="${PRESET_LIST[$reply]}"
}

cleanup_worktrees() {
  local dir name size running='' i=0 reply n
  demo_running && running="$S_WORKTREE"
  CLEAN_PATHS=()
  printf '\n%sWorktrees — %s%s\n\n' "$C_BLD" "$NAME" "$C_OFF"
  for dir in "$WORKTREES"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    i=$((i + 1)); CLEAN_PATHS[$i]="$dir"
    if [ "$dir" = "$running" ]; then
      printf '  %2d.  %-34s %6s  %s(running — stop it first)%s\n' "$i" "$name" "$size" "$C_YEL" "$C_OFF"
    else
      printf '  %2d.  %-34s %6s\n' "$i" "$name" "$size"
    fi
  done
  [ "$i" -gt 0 ] || { info "No worktrees to remove."; return 0; }
  printf '\n  Numbers to remove (space separated), or Return to cancel: '
  read -r reply || reply=''
  [ -n "$reply" ] || return 0
  for n in $reply; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || continue
    dir="${CLEAN_PATHS[$n]}"
    if [ "$dir" = "$running" ]; then warn "skipped $(basename "$dir") — still running"; continue; fi
    repo_git worktree remove --force "$dir" >/dev/null 2>&1 || {
      safe_rm_worktree "$dir"; repo_git worktree prune >/dev/null 2>&1
    }
    ok "removed $(basename "$dir")"
  done
  repo_git worktree prune >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

usage() {
  cat <<USAGE
Runbranch — run any local project from a throwaway git worktree.

  runbranch.sh                          interactive
  runbranch.sh run <project> <ref> <preset>
  runbranch.sh stop <project>
  runbranch.sh status [<project>]
  runbranch.sh cleanup <project>

  machine-readable, used by runbranch.app:
  runbranch.sh projects
  runbranch.sh branches <project>
  runbranch.sh presets <project>
  runbranch.sh paths <project> [<ref>]
  runbranch.sh reclaim [<project>]     reclaim ports and clear state a crash left
  runbranch.sh state <project>
  runbranch.sh remove-worktree <project> <ref>
  runbranch.sh refresh <project>

Projects   : $PROJECTS_DIR
State      : $RB_HOME/<project>/
USAGE
}

need_project() {
  [ $# -ge 1 ] && [ -n "${1:-}" ] || { usage; exit 2; }
  load_project "$1"
}

main() {
  harden_path
  case "${1:-menu}" in
    projects) list_projects ;;
    branches) need_project "${2:-}"; collect_branch_data /dev/stdout ;;
    paths)
      # Where things live, so the app never hardcodes the layout.
      #   worktrees <TAB> logs <TAB> config <TAB> repo [<TAB> worktree-for-ref]
      need_project "${2:-}"
      printf '%s\t%s\t%s\t%s' "$WORKTREES" "$LOG_DIR" "$PROJECTS_DIR/$PROJECT.conf" "$REPO"
      [ $# -ge 3 ] && printf '\t%s' "$(worktree_path "$3")"
      printf '\n'
      ;;
    presets)  need_project "${2:-}"; preset_names ;;
    state)
      local t pid
      need_project "${2:-}"
      if ! demo_running; then printf 'idle\n'; exit 0; fi
      printf 'run\t%s\t%s\t%s\t%s\t%s\n' \
        "$S_REF" "$S_PRESET" "$S_STARTED" "$S_EPOCH" "$S_WORKTREE"
      # TARGETS and PIDS are written in the same order, so they zip.
      set -- $S_PIDS
      for t in $S_TARGETS; do
        pid="${1:-}"; [ $# -gt 0 ] && shift
        printf 'target\t%s\t%s\t%s\t%s\t%s\n' "$t" \
          "$(target_field "$t" port)" "$(target_field "$t" health)" \
          "${pid:-0}" "$(alive "${pid:-}" && echo 1 || echo 0)"
      done
      ;;
    refresh) need_project "${2:-}"; refresh_pr_cache && echo "refreshed" || echo "refresh failed" >&2 ;;
    reclaim)
      if [ $# -ge 2 ]; then load_project "$2"; reclaim_project || true
      else reclaim_all; fi
      ;;
    remove-worktree)
      [ $# -eq 3 ] || { usage; exit 2; }
      load_project "$2"; remove_worktree_for "$3"
      ;;
    run)
      [ $# -eq 4 ] || { usage; exit 2; }
      load_project "$2"; do_run "$3" "$4"
      ;;
    stop) need_project "${2:-}"; stop_run ;;
    status)
      if [ $# -ge 2 ]; then load_project "$2"; print_status; exit $?; fi
      local any=1 n
      while IFS="$(printf '\t')" read -r n _; do
        [ -n "$n" ] || continue
        ( load_project "$n"; print_status >/dev/null 2>&1 && print_status ) && any=0
      done <<EOF
$(list_projects)
EOF
      [ "$any" = 0 ] || printf '\nNothing running.\n\n'
      exit "$any"
      ;;
    cleanup) need_project "${2:-}"; cleanup_worktrees ;;
    -h|--help|help) usage ;;
    menu|'')
      [ "$HAVE_TTY" = 1 ] || die "This is the engine, not the front end." \
        "open '$SELF_DIR/Runbranch.app'"
      pick_project || exit 0
      load_project "$PICKED_PROJECT"
      if demo_running; then
        print_status
        ask "Stop it?" 1 && stop_run
        exit 0
      fi
      pick_branch  || exit 0
      pick_preset  || exit 0
      do_run "$PICKED_REF" "$PICKED_PRESET"
      ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
