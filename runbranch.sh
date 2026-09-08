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
IN_REPO_CONFIG=''

# Favourites are a personal preference rather than a property of the project,
# so they live in RB_HOME and not in a .conf that might be committed.
FAVOURITES_FILE="$RB_HOME/favourites"

is_favourite() {
  [ -f "$FAVOURITES_FILE" ] || return 1
  grep -qxF "$1" "$FAVOURITES_FILE"
}

set_favourite() {
  local name="$1" on="$2" tmp
  mkdir -p "$(dirname "$FAVOURITES_FILE")"
  touch "$FAVOURITES_FILE"
  tmp="$FAVOURITES_FILE.$$"
  grep -vxF "$name" "$FAVOURITES_FILE" > "$tmp" 2>/dev/null || true
  [ "$on" = on ] && printf '%s\n' "$name" >> "$tmp"
  mv "$tmp" "$FAVOURITES_FILE"
  ok "$name $( [ "$on" = on ] && echo added to || echo removed from ) favourites"
}

expand_repo() { case "$REPO" in "~"*) REPO="$HOME${REPO#\~}" ;; esac; }

# Reset on every load so a second load cannot inherit the first, and so the
# in-repo file and the local one both start from the same place.
reset_project_defaults() {
  PORT_OFFSET=0
  NAME=""; REPO=""; DEFAULT_BRANCH="main"; INSTALL=""; COPY_FILES=""
  COMPOSE_FILE="docker-compose.yml"; COMPOSE_PROJECT=""; COMPOSE_SERVICES=""
  MIGRATE=""; SEED=""; TARGETS=""; ALWAYS=""; PRESETS=""; OPENS_ITSELF=0; SYMBOL=""
  PROCFILE=0; PORT_BASE=5000; RUNTIME=""; PORTS="fixed"
  DB_URL_VARS=""; DB_TEMPLATE=""; DB_ADMIN_USER=""
}

load_project() {
  # Split deliberately: bash expands every argument to `local` BEFORE it
  # assigns any of them, so $name in the same statement reads the unset global.
  local name="$1"
  local file="$PROJECTS_DIR/$name.conf"
  [ -f "$file" ] || die "No project called \"$name\"." \
    "ls $PROJECTS_DIR    # or add $name.conf there"

  reset_project_defaults

  # shellcheck disable=SC1090
  . "$file"

  # A project can keep its definition in the repo, where the team can review it
  # in a pull request and a new machine gets it from the clone. The local file
  # still wins, so one person can override a port or a preset without changing
  # what everyone else runs.
  #
  # The order below is why: the local file is read first for REPO, the in-repo
  # file is then read as the base, and the local file is read again on top.
  expand_repo
  if [ -f "$REPO/.runbranch" ]; then
    IN_REPO_CONFIG="$REPO/.runbranch"
    reset_project_defaults
    # shellcheck disable=SC1090
    . "$IN_REPO_CONFIG"
    # shellcheck disable=SC1090
    . "$file"
    # The second pass reset REPO to whatever the local file literally says,
    # so expand it again rather than leaving a tilde in a path.
    expand_repo
  else
    IN_REPO_CONFIG=""
  fi

  PROJECT="$name"
  [ -n "$NAME" ] || NAME="$name"
  [ -n "$REPO" ] || die "$name.conf sets no REPO." "edit $file"
  [ -d "$REPO/.git" ] || die "$NAME: $REPO is not a git repository." "edit $file"
  # A Procfile already IS a target list: `name: command`, one per line. Foreman
  # assigns each process a PORT; we do the same so a health check has somewhere
  # to look, and export it the way the app expects.
  if [ "$PROCFILE" = 1 ] && [ -z "$TARGETS" ]; then
    TARGETS="$(procfile_targets "$REPO/Procfile")"
    [ -n "$TARGETS" ] || die "$name.conf sets PROCFILE=1 but $REPO/Procfile has no processes." \
      "cat $REPO/Procfile"
  fi
  [ -n "$TARGETS" ] || die "$name.conf declares no TARGETS." "edit $file"

  WORK_ROOT="$RB_HOME/$name"
  WORKTREES="$WORK_ROOT/worktrees"
  LOG_DIR="$WORK_ROOT/logs"
  STATE_FILE="$WORK_ROOT/state"
  PR_CACHE="$WORK_ROOT/prcache"
  META_DIR="$WORK_ROOT/meta"
}

# Procfile -> TARGETS. Ports are assigned, not declared, because a Procfile
# never says: foreman's convention is a base incremented per process.
procfile_targets() {
  local file="$1" i=0
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *:*) ;; *) continue ;; esac
    local pname cmd
    pname="${line%%:*}"
    cmd="${line#*:}"
    # Trim leading space without invoking anything.
    while case "$cmd" in ' '*) true ;; *) false ;; esac; do cmd="${cmd# }"; done
    printf '%s:%s:/:PORT=%s %s\n' "$pname" "$((PORT_BASE + i * 100))" \
      "$((PORT_BASE + i * 100))" "$cmd"
    i=$((i + 1))
  done <"$file"
}

list_projects() {
  local f name
  [ -d "$PROJECTS_DIR" ] || return 0
  for f in "$PROJECTS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .conf)"
    ( load_project "$name" >/dev/null 2>&1 || exit 0
      [ -n "$PROJECT" ] || exit 0
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$NAME" "$REPO" \
        "$( [ -f "$STATE_FILE" ] && echo 1 || echo 0 )" "${SYMBOL:-shippingbox}" \
        "$( is_favourite "$name" && echo 1 || echo 0 )" )
  done
}

# An offset added to every declared port for this run.
#
# Ports are declared in the config and that is deliberate — a stack that bakes
# its origins in (an OAuth origin, a CORS allowlist, an API URL compiled into
# the client) has to stay where it was told. But framework defaults collide
# across projects, so a run can be shifted wholesale when the user asks for it.
#
# Every target moves by the same amount, so the relative layout a stack may
# depend on survives: api 4000 and web 3000 become 4001 and 3001, not 4001 and
# 4002.
PORT_OFFSET=0

# The port a target actually listens on, as opposed to the one it declares.
# Runtime paths use this; `doctor` reports the declared one, since that is what
# is written in the file.
target_port() {
  local declared
  declared="$(target_field "$1" port)" || return 1
  [ -n "$declared" ] || return 1
  printf '%s' "$((declared + PORT_OFFSET))"
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
  drop_run_database "$wt" "$ref"
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

# A repo that pins its toolchain expects that pin to be honoured. The activation
# has to happen INSIDE the worktree, because that is where .nvmrc / .tool-versions
# / mise.toml live — activating in the launcher's own directory reads the wrong
# pin, or none.
runtime_prelude() {
  case "$RUNTIME" in
    mise) printf 'eval "$(mise activate bash --shims 2>/dev/null || true)"; ' ;;
    fnm)  printf 'eval "$(fnm env 2>/dev/null || true)"; fnm use --install-if-missing >/dev/null 2>&1 || true; ' ;;
    asdf) printf '. "$(brew --prefix asdf 2>/dev/null)/libexec/asdf.sh" 2>/dev/null || true; ' ;;
    nvm)  printf '. "$HOME/.nvm/nvm.sh" 2>/dev/null && nvm use >/dev/null 2>&1 || true; ' ;;
    "")   ;;
    *)    ;;
  esac
}

# Run a command in the worktree with the project's runtime active.
in_worktree() {
  local wt="$1" cmd="$2"
  ( cd "$wt" && eval "$(runtime_prelude)$cmd" )
}

GH_PACKAGES_REFRESH='gh auth refresh -h github.com -s read:packages'

install_deps() {
  local wt="$1" log="$LOG_DIR/install.log" rc
  [ -n "$INSTALL" ] || return 0
  step "Dependencies"
  info "$INSTALL   (first run on a branch can take a few minutes)"
  info "logging to $log"
  printf '\n'
  ( cd "$wt" && eval "$(runtime_prelude)$INSTALL" 2>&1 ) | tee "$log"
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
  in_worktree "$wt" "$MIGRATE" || die "Migrations failed." "cd $wt && $MIGRATE"
  ok "migrations applied"
}

# An empty app is not worth looking at.
run_seed() {
  local wt="$1"
  [ -n "$SEED" ] || return 0
  step "Seed"
  info "$SEED"
  in_worktree "$wt" "$SEED" || die "Seeding failed." "cd $wt && $SEED"
  ok "seeded"
}

# The compose container id for a service, so we can run psql inside it rather
# than requiring a client on the host.
pg_container() { compose "$1" ps -q postgres 2>/dev/null | head -1; }

# ---------------------------------------------------------------------------
# Per-run databases
#
# Two branches with divergent migrations sharing one database is the oldest
# problem this tool has: migrating for one silently rewrites the other, and
# nothing rolls it back. A branch can have its own database instead — created
# with the worktree, migrated and seeded from scratch, dropped when the
# worktree goes.
#
# Postgres only, and declared rather than assumed: a project says which
# variable carries its URL, because only it knows.
# ---------------------------------------------------------------------------

# postgresql://user:pass@host:port/dbname -> dbname
db_name_from_url() { printf '%s' "$1" | sed -E 's#^.*/([^/?]+)(\?.*)?$#\1#'; }

# The URL as the main checkout has it, which is the one to derive from.
db_source_url() {
  local var="$1" f
  for f in $COPY_FILES; do
    [ -f "$REPO/$f" ] || continue
    grep -E "^${var}=" "$REPO/$f" | tail -1 | sed -E "s/^${var}=//" | tr -d '"'"'" && return 0
  done
  return 1
}

# Postgres identifiers cap at 63 bytes, and a branch slug can be longer.
db_name_for() {
  local base="$1" slug="$2"
  printf '%s' "${base}_rb_${slug}" | tr -c 'A-Za-z0-9_' '_' | cut -c1-63
}

psql_admin() {
  local wt="$1" sql="$2" cid user
  cid="$(pg_container "$wt")"
  [ -n "$cid" ] || die \
    "$NAME declares DB_URL_VARS but has no running postgres service to create the database in." \
    "check COMPOSE_SERVICES in $PROJECTS_DIR/$PROJECT.conf names postgres"
  user="${DB_ADMIN_USER:-$(printf '%s' "$DB_BASE_URL" | sed -E 's#^[a-z]+://([^:]+):.*#\1#')}"
  docker exec "$cid" psql -U "$user" -d postgres -v ON_ERROR_STOP=1 -tAc "$sql"
}

# Sets DB_RUN_NAME. Creates the database if it is not already there.
DB_RUN_NAME=''
DB_BASE_URL=''
setup_run_database() {
  local wt="$1" ref="$2" var first base exists
  DB_RUN_NAME=''
  [ -n "$DB_URL_VARS" ] || return 0

  first="${DB_URL_VARS%% *}"
  DB_BASE_URL="$(db_source_url "$first")"
  [ -n "$DB_BASE_URL" ] || die \
    "$NAME declares DB_URL_VARS=\"$DB_URL_VARS\" but $first is not set in ${COPY_FILES:-<COPY_FILES>}." \
    "grep $first $REPO/${COPY_FILES%% *}"

  base="$(db_name_from_url "$DB_BASE_URL")"
  DB_RUN_NAME="$(db_name_for "$base" "$(slug_for "$ref")")"

  step "Database  $DB_RUN_NAME"
  exists="$(psql_admin "$wt" "SELECT 1 FROM pg_database WHERE datname='$DB_RUN_NAME'" 2>/dev/null)"
  if [ "$exists" = 1 ]; then
    ok "already exists — reusing it"
  else
    if [ -n "$DB_TEMPLATE" ]; then
      info "creating from template $DB_TEMPLATE"
      psql_admin "$wt" "CREATE DATABASE \"$DB_RUN_NAME\" TEMPLATE \"$DB_TEMPLATE\"" >/dev/null || die \
        "Could not create $DB_RUN_NAME from template $DB_TEMPLATE." \
        "docker exec -it $(pg_container "$wt") psql -U ${DB_ADMIN_USER:-postgres} -c 'CREATE DATABASE \"$DB_RUN_NAME\"'"
    else
      info "creating"
      psql_admin "$wt" "CREATE DATABASE \"$DB_RUN_NAME\"" >/dev/null || die \
        "Could not create $DB_RUN_NAME." \
        "docker exec -it $(pg_container "$wt") psql -U ${DB_ADMIN_USER:-postgres} -c 'CREATE DATABASE \"$DB_RUN_NAME\"'"
    fi
    ok "created"
  fi

  # Point the worktree's own copies at it. Rewriting the file rather than
  # relying on an exported variable, because dotenv loaders differ on which
  # wins and a file you can read is easier to trust than a precedence rule.
  local f
  for var in $DB_URL_VARS; do
    for f in $COPY_FILES; do
      [ -f "$wt/$f" ] || continue
      local newurl
      newurl="$(printf '%s' "$DB_BASE_URL" | sed -E "s#/[^/?]+(\?.*)?\$#/$DB_RUN_NAME\1#")"
      /usr/bin/sed -i '' -E "s#^${var}=.*#${var}=${newurl}#" "$wt/$f"
    done
  done
  ok "$COPY_FILES now points at $DB_RUN_NAME"
}

drop_run_database() {
  local wt="$1" ref="$2" base name
  [ -n "$DB_URL_VARS" ] || return 0
  DB_BASE_URL="$(db_source_url "${DB_URL_VARS%% *}")" || return 0
  [ -n "$DB_BASE_URL" ] || return 0
  base="$(db_name_from_url "$DB_BASE_URL")"
  name="$(db_name_for "$base" "$(slug_for "$ref")")"
  # Never the base database, whatever the arithmetic said.
  [ "$name" = "$base" ] && return 0
  psql_admin "$wt" "DROP DATABASE IF EXISTS \"$name\" WITH (FORCE)" >/dev/null 2>&1 \
    && ok "dropped $name"
  return 0
}

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------

port_holder() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1; }
port_holder_desc() { ps -o pid=,command= -p "$1" 2>/dev/null | sed -e 's/^ *//' | cut -c1-110; }

# Which project owns a process, if any. Anything we started runs inside a
# worktree under RB_HOME, and the first path segment after it is the project —
# so a port conflict can name the run holding the port rather than leaving the
# user to work it out from a command line.
port_holder_project() {
  local pid="$1"
  local cmd cwd hay
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  # The command line carries the worktree path only when the process was
  # started with an absolute one — `node /path/to/.bin/vite` does, `python3 -m
  # http.server` does not. The working directory is the worktree either way.
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  hay="$cmd $cwd"
  case "$hay" in
    *"$RB_HOME/"*)
      local after
      after="${hay#*"$RB_HOME"/}"
      printf '%s' "${after%%/*}"
      ;;
  esac
}

# Ports declared by more than one project.
#
# Nothing stops two configs claiming the same port — and framework defaults
# make it likely, since every Vite project wants 5173 and every Next one wants
# 3000. It only surfaces when the second project refuses to start, which is a
# bad time to find out. So `doctor` with no argument says so up front.
report_port_overlaps() {
  local n port line pairs=''
  while IFS="$(printf '\t')" read -r n _; do
    [ -n "$n" ] || continue
    # target_field matches by NAME, so the names have to come from
    # target_names — splitting $TARGETS on whitespace yields fragments of the
    # command, not names.
    for port in $( ( load_project "$n" >/dev/null 2>&1
                     # target_field prints without a trailing newline, so
                     # without the echo three ports become "400030003002".
                     for t in $(target_names); do target_field "$t" port; echo; done
                   ) 2>/dev/null ); do
      [ -n "$port" ] || continue
      pairs="$pairs$port $n
"
    done
  done <<EOF
$(list_projects)
EOF

  local overlaps
  # `sort -u` and not `sort -n -u`: with a numeric sort, uniqueness is decided
  # by the numeric KEY, so every line sharing a port collapses into one and the
  # count is always 1 — which is exactly the thing being counted.
  overlaps="$(printf '%s' "$pairs" | sort -u | awk '
    { count[$1] = count[$1] + 1; who[$1] = who[$1] " " $2 }
    END { for (p in count) if (count[p] > 1) print p, who[p] }
  ' | sort -n)"
  [ -n "$overlaps" ] || return 0

  warn "These ports are claimed by more than one project, so those projects
cannot run at the same time:"
  printf '%s\n' "$overlaps" | while read -r port rest; do
    printf '    %-6s %s\n' "$port" "$rest"
  done
  printf '\n  To run them together, give one a different port — in the target AND in
  the command, since a framework will not pick it up otherwise:\n
    TARGETS="docs:5174:/:npm run docs -- --port 5174"\n\n'
  return 0
}

# What stands between a preset and starting, in a form the front end can act on.
#
# One line per conflicted target:
#   target <TAB> declared <TAB> owner <TAB> pid <TAB> overridable
# `owner` is the project whose run holds the port, or empty for something the
# user started. `overridable` is 1 when the command contains {port}, meaning the
# run can be shifted; 0 when shifting it would just health-check an empty port.
#
# A trailing OFFSET line gives the smallest shift that clears every conflict.
check_ports() {
  local targets="$1"
  local t port pid owner cmd overridable found=0
  for t in $targets; do
    port="$(target_port "$t")"
    [ -n "$port" ] || continue
    pid=$(port_holder "$port")
    [ -n "$pid" ] || continue
    found=1
    owner="$(port_holder_project "$pid")"
    cmd="$(target_field "$t" command)"
    case "$cmd" in *'{port}'*) overridable=1 ;; *) overridable=0 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$t" "$port" "$owner" "$pid" "$overridable"
  done
  [ "$found" = 0 ] && return 0

  # Walk up until every port in the preset is free. Same shift for all of them.
  local try=1 clash
  while [ "$try" -le 200 ]; do
    clash=0
    for t in $targets; do
      port="$(target_field "$t" port)"
      [ -n "$port" ] || continue
      [ -n "$(port_holder "$((port + try))")" ] && { clash=1; break; }
    done
    [ "$clash" = 0 ] && break
    try=$((try + 1))
  done
  printf 'OFFSET\t%s\n' "$try"
  return 1
}

ensure_ports_free() {
  local targets="$1"
  local t port pid owner busy='' owners=''
  for t in $targets; do
    port="$(target_port "$t")"
    [ -n "$port" ] || continue
    pid=$(port_holder "$port")
    [ -n "$pid" ] || continue
    owner="$(port_holder_project "$pid")"
    if [ -n "$owner" ]; then
      busy="$busy
  $t on port $port  ->  Runbranch is running $owner here (pid $pid)"
      case " $owners " in *" $owner "*) ;; *) owners="$owners $owner" ;; esac
    else
      busy="$busy
  $t on port $port  ->  $(port_holder_desc "$pid")"
    fi
  done
  [ -z "$busy" ] && return 0

  # A port held by one of our own runs is a different problem from a port held
  # by something the user started, and it has a different fix. Saying "stop
  # $PROJECT" when the holder belongs to another project sends them after the
  # wrong thing.
  if [ -n "$owners" ]; then
    local fix='' o
    for o in $owners; do
      fix="$fix$SELF stop $o
    "
    done
    die "Ports this project needs are held by another Runbranch run:
$busy

Two projects that both default to the same port cannot run at once. Stop the
other run, or give one of them different ports in its config." \
      "$fix# then start this one again
    $SELF get $PROJECT | grep TARGETS      # to change ports instead"
  fi

  die "Something is already listening on a port this needs:
$busy

If that is your own dev server, leave it alone and stop it yourself." \
    "$SELF stop $PROJECT      # a leftover run of this project
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
  # A framework will not discover the offset on its own. `{port}` in the command
  # is how a config says where to put it — without one, a shifted run would
  # health-check a port nothing is listening on.
  local actual
  actual="$(target_port "$name")"
  cmd="${cmd//\{port\}/$actual}"
  log="$LOG_DIR/$name.log"
  mkdir -p "$LOG_DIR"
  : >"$log"
  set -m
  ( cd "$wt" && exec nohup /bin/bash -c "$(runtime_prelude)$cmd" ) >"$log" 2>&1 &
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
    printf 'PORT_OFFSET=%s\n' "$PORT_OFFSET"
    printf 'STARTED=%s\n'  "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'EPOCH=%s\n'    "$(date +%s)"
  } >"$STATE_FILE"
}

load_state() {
  S_REF=''; S_WORKTREE=''; S_PRESET=''; S_TARGETS=''; S_PIDS=''; S_STARTED=''; S_EPOCH=0
  # PORT_OFFSET is deliberately NOT reset here. load_project already zeroes it,
  # and do_run reads state (through demo_running) AFTER the caller has asked for
  # an offset — resetting it here silently discarded the request and the run
  # then checked, and started on, the declared ports.
  [ -f "$STATE_FILE" ] || return 1
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      REF) S_REF="$val" ;; WORKTREE) S_WORKTREE="$val" ;;
      PRESET) S_PRESET="$val" ;; TARGETS) S_TARGETS="$val" ;;
      PIDS) S_PIDS="$val" ;; STARTED) S_STARTED="$val" ;; EPOCH) S_EPOCH="$val" ;;
      # Restore the offset the run was started with, so stop, status and health
      # look at the ports it is really on rather than the declared ones.
      PORT_OFFSET) PORT_OFFSET="$val" ;;
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
    port="$(target_port "$t")"
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
    port="$(target_port "$t")"
    [ -n "$port" ] && info "$(printf '%-8s' "$t") http://localhost:$port"
  done
  # Some dev servers (vite --open) open a browser themselves; opening a second
  # one is just a duplicate tab. RB_NO_OPEN exists for tests and scripts —
  # a suite that steals focus every time it runs is a suite people stop running.
  if [ "$OPENS_ITSELF" != 1 ] && [ -z "${RB_NO_OPEN:-}" ] && [ -n "$first" ]; then
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
    port="$(target_port "$t")"
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
  setup_run_database "$WORKTREE" "$ref"
  handle_migrations "$WORKTREE"
  run_seed          "$WORKTREE"
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
      port="$(target_port "$t")"
      [ -n "$port" ] && printf '  %-9s http://localhost:%s\n' "$t" "$port"
    done
    printf '  logs      %s\n\n' "$LOG_DIR"
    return 0
  fi
  printf '\n%s: nothing running.\n\n' "$NAME"
  return 1
}

# ---------------------------------------------------------------------------
# propose — read a repo and guess its config
#
# Nobody should face a blank config file. Almost everything a project needs is
# already declared somewhere in the repo: the lockfile names the package
# manager, package.json names the scripts, the dev script usually names its own
# port, a Procfile names the processes, compose names the services, and .nvmrc
# or mise.toml names the toolchain.
#
# It guesses. It says so, and the guesses are commented so they are easy to
# correct. Better a wrong port you can see than a blank file you must research.
# ---------------------------------------------------------------------------

# A value out of package.json without pulling in a JSON parser as a dependency
# for the whole engine. python3 ships with the command line tools, which are
# already required to build the app.
pkg_script() {
  local dir="$1" key="$2"
  [ -f "$dir/package.json" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$dir/package.json" "$key" <<'PYEOF' 2>/dev/null
import json,sys
try: print(json.load(open(sys.argv[1])).get("scripts",{}).get(sys.argv[2],""))
except Exception: pass
PYEOF
}

# --port 3000, -p 3000, --port=3000, PORT=3000
port_from_command() {
  printf '%s' "$1" | sed -nE 's/.*(--port[= ]|(^| )-p )([0-9]{2,5}).*/\3/p' | head -1
}

# Framework defaults, for when the script does not say.
port_from_framework() {
  case "$1" in
    *next*)    printf '3000' ;;
    *vite*)    printf '5173' ;;
    *astro*)   printf '4321' ;;
    *remix*)   printf '3000' ;;
    *nuxt*)    printf '3000' ;;
    *storybook*) printf '6006' ;;
    *rails*|*puma*) printf '3000' ;;
    *django*|*manage.py*) printf '8000' ;;
    *) printf '' ;;
  esac
}

propose_config() {
  local dir="$1" name pm install dev port runtime defbr copy compose svc
  dir="${dir%/}"
  [ -d "$dir/.git" ] || die "$dir is not a git repository." "runbranch.sh propose <path-to-repo>"
  name="$(basename "$dir" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9._-]/-/g')"

  # Package manager, from the lockfile that is present.
  if   [ -f "$dir/pnpm-lock.yaml" ];   then pm=pnpm;  install="pnpm install --frozen-lockfile"
  elif [ -f "$dir/bun.lockb" ];        then pm=bun;   install="bun install --frozen-lockfile"
  elif [ -f "$dir/yarn.lock" ];        then pm=yarn;  install="yarn install --immutable"
  elif [ -f "$dir/package-lock.json" ];then pm=npm;   install="npm ci"
  elif [ -f "$dir/Gemfile.lock" ];     then pm=bundle;install="bundle install"
  elif [ -f "$dir/uv.lock" ];          then pm=uv;    install="uv sync"
  elif [ -f "$dir/poetry.lock" ];      then pm=poetry;install="poetry install"
  elif [ -f "$dir/Cargo.lock" ];       then pm=cargo; install=""
  else pm=""; install=""; fi

  # The script to run. Not every repo calls it `dev` — a component library is
  # as likely to call it `docs` or `storybook` — and the target should be named
  # after whichever one it actually is.
  local key raw=""
  for key in dev start docs storybook serve; do
    raw="$(pkg_script "$dir" "$key")"
    [ -n "$raw" ] && break
  done
  [ -n "$raw" ] || key="dev"
  if [ -n "$raw" ] && [ -n "$pm" ]; then dev="$pm run $key"; else dev=""; fi

  port="$(port_from_command "$raw")"
  [ -n "$port" ] || port="$(port_from_framework "$raw")"
  [ -n "$port" ] || port=3000

  # Toolchain pin.
  if   [ -f "$dir/mise.toml" ] || [ -f "$dir/.mise.toml" ]; then runtime=mise
  elif [ -f "$dir/.tool-versions" ]; then runtime=asdf
  elif [ -f "$dir/.nvmrc" ]; then runtime=fnm
  else runtime=""; fi

  defbr="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$defbr" ] || defbr="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  # Gitignored config a worktree would not get.
  copy=""
  for f in .env.local .env .env.development; do
    if [ -f "$dir/$f" ] && git -C "$dir" check-ignore -q "$f" 2>/dev/null; then
      copy="$copy $f"
    fi
  done
  copy="${copy# }"

  # Compose services worth waiting for.
  compose=""; svc=""
  for f in docker-compose.yml compose.yaml compose.yml docker-compose.yaml; do
    [ -f "$dir/$f" ] || continue
    compose="$f"
    # Only the services: block. A naive grep also matches the volumes: block,
    # where `postgres-data` sits at the same indent and is not a service.
    svc="$(awk '
      /^[a-z]+:/ { section = $1; next }
      section == "services:" && /^  [a-zA-Z0-9_-]+:/ {
        name = $1; sub(/:$/, "", name)
        if (name ~ /^(postgres|postgresql|mysql|mariadb|redis|valkey|mongo|mongodb|elasticsearch|rabbitmq)/)
          printf "%s ", name
      }
    ' "$dir/$f")"
    svc="${svc% }"
    break
  done

  printf '# Proposed by `runbranch propose` on %s.\n' "$(date '+%Y-%m-%d')"
  printf '# Every value is a guess read out of the repo. Correct anything wrong,\n'
  printf '# then check it with: runbranch.sh doctor %s\n\n' "$name"
  printf 'NAME="%s"\n' "$(basename "$dir")"
  printf 'REPO="%s"\n' "$(printf '%s' "$dir" | sed "s#^$HOME#~#")"
  printf 'DEFAULT_BRANCH="%s"\n' "${defbr:-main}"
  [ -n "$install" ] && printf 'INSTALL="%s"\n' "$install"
  [ -n "$runtime" ] && printf 'RUNTIME="%s"          # pinned in the repo\n' "$runtime"
  [ -n "$copy" ]    && printf 'COPY_FILES="%s"    # gitignored, so a worktree lacks it\n' "$copy"
  if [ -n "$svc" ]; then
    printf 'COMPOSE_FILE="%s"\n' "$compose"
    printf 'COMPOSE_PROJECT="%s"\n' "$name"
    printf 'COMPOSE_SERVICES="%s"\n' "$svc"
  fi
  if [ -f "$dir/Procfile" ]; then
    printf '\n# This repo has a Procfile, which already lists what to run.\n'
    printf 'PROCFILE=1\n'
  else
    printf '\n# port guessed from %s\n' \
      "$( [ -n "$(port_from_command "$raw")" ] && echo 'the dev script' || echo 'the framework default' )"
    if [ -n "$dev" ]; then
      printf 'TARGETS="%s:%s:/:%s"\n' "$key" "$port" "$dev"
    else
      # Nothing in the repo said how to run it. Better an obvious blank than a
      # plausible command that fails minutes later.
      printf '# Nothing in this repo says how to run it -- no lockfile, no\n'
      printf '# package.json script. Fill this in, then: runbranch.sh doctor %s\n' "$name"
      printf 'TARGETS="dev:%s:/:REPLACE-ME"\n' "$port"
    fi
  fi
  case "$raw" in *--open*) printf 'OPENS_ITSELF=1        # the dev server opens a browser itself\n' ;; esac
  printf 'SYMBOL="shippingbox"\n'
}

# Write a proposed config. Never overwrites: a config you have corrected is
# worth more than a fresh guess.
# Remove a project's declaration, and the state Runbranch created for it.
#
# Deliberately never touches the repository. That is the user's actual work and
# it is not ours to delete; a project is a config file plus whatever we put in
# RB_HOME, and both of those we made.
remove_project() {
  local name="$1"
  local conf="$PROJECTS_DIR/$name.conf"
  [ -f "$conf" ] || die "No such project: $name" "runbranch.sh projects"

  # Refuse while it is running. Removing the config underneath a live run would
  # orphan the servers with nothing left that knows how to stop them.
  local state="$RB_HOME/$name/current"
  if [ -f "$state" ]; then
    die "$name is running." "runbranch.sh stop $name"
  fi

  rm -f "$conf"
  # Worktrees, logs and metadata. Anything here was created by us.
  [ -d "$RB_HOME/$name" ] && rm -rf "$RB_HOME/$name"
  # And the favourite pin, which lives outside the config on purpose.
  if [ -f "$FAVOURITES_FILE" ]; then
    grep -vxF "$name" "$FAVOURITES_FILE" > "$FAVOURITES_FILE.tmp" 2>/dev/null || true
    mv "$FAVOURITES_FILE.tmp" "$FAVOURITES_FILE"
  fi
  info "Removed $name. Its repository was not touched."
}

add_project() {
  local dir="$1" name out
  dir="${dir%/}"
  [ -d "$dir/.git" ] || die "$dir is not a git repository." "runbranch.sh add <path-to-repo>"
  name="$(basename "$dir" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9._-]/-/g')"
  out="$PROJECTS_DIR/$name.conf"
  [ -e "$out" ] && die "$name is already declared." "open $out"
  mkdir -p "$PROJECTS_DIR"
  propose_config "$dir" >"$out" || { rm -f "$out"; die "Could not read $dir." "runbranch.sh propose '$dir'"; }
  printf '%s\t%s\n' "$name" "$out"
}

# Rewrite one key in a project's local conf, preserving everything else --
# including comments, which are usually the only explanation of why a value is
# what it is.
#
# Done in python rather than awk. The first version passed the value through
# `awk -v`, which cannot carry a newline, so writing a multi-line TARGETS
# emptied the file. A config is not something to be clever with, so it is also
# backed up before writing and restored if the result will not parse.
set_project_key() {
  local name="$1" key="$2" value="$3"
  local file="$PROJECTS_DIR/$name.conf"
  [ -f "$file" ] || die "No config at $file." "runbranch.sh add <repo>"
  case "$key" in
    [A-Z][A-Z_]*) ;;
    *) die "\"$key\" is not a config key." "runbranch.sh get $name" ;;
  esac

  cp "$file" "$file.bak"
  if ! KEY="$key" VALUE="$value" python3 - "$file" <<'PYEOF'
import os, re, sys

path  = sys.argv[1]
key   = os.environ["KEY"]
# \001 stands in for a newline on the way through the shell.
value = os.environ["VALUE"].replace("\001", "\n")

lines = open(path).read().split("\n")
out, i, replaced = [], 0, False
assign = re.compile(rf'^{re.escape(key)}=')

while i < len(lines):
    line = lines[i]
    if assign.match(line):
        out.append(f'{key}="{value}"')
        replaced = True
        # Skip any continuation lines: a value whose opening quote is not
        # closed on the same line runs on until one is.
        rest = line[len(key) + 1:]
        if rest.startswith('"') and not re.search(r'"\s*$', rest[1:] or '"'):
            i += 1
            while i < len(lines) and not re.search(r'"\s*$', lines[i]):
                i += 1
        i += 1
        continue
    out.append(line)
    i += 1

if not replaced:
    while out and out[-1] == "":
        out.pop()
    out.append(f'{key}="{value}"')
    out.append("")

open(path, "w").write("\n".join(out))
PYEOF
  then
    mv "$file.bak" "$file"
    die "Could not rewrite $key; the config is unchanged." "edit $file"
  fi

  # Prove it still parses before believing the write.
  if ! ( load_project "$name" >/dev/null 2>&1 ); then
    mv "$file.bak" "$file"
    die "Setting $key produced a config that will not load; reverted." "edit $file"
  fi
  rm -f "$file.bak"
  ok "$key set in $file"
}

# Git repos under a directory that are not already declared.
scan_repos() {
  local root="${1:-$HOME/Development}" d name
  [ -d "$root" ] || die "$root does not exist." "runbranch.sh scan <directory>"
  find "$root" -maxdepth 3 -type d -name .git -not -path "*/node_modules/*" 2>/dev/null \
    | sed 's#/\.git$##' | sort | while IFS= read -r d; do
    name="$(basename "$d" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9._-]/-/g')"
    [ -f "$PROJECTS_DIR/$name.conf" ] && continue
    grep -lF "\"$d\"" "$PROJECTS_DIR"/*.conf >/dev/null 2>&1 && continue
    printf '%s\t%s\n' "$name" "$d"
  done
}

# ---------------------------------------------------------------------------
# doctor — check a project's config before you need it
#
# Every one of these is something that would otherwise surface minutes into a
# run, as a failure that looks like the branch's fault.
# ---------------------------------------------------------------------------

# The first word of a command, which is the thing that has to exist.
cmd_head() { printf '%s' "$1" | awk '{for(i=1;i<=NF;i++){if($i !~ /=/){print $i; exit}}}'; }

doctor_project() {
  local bad=0 t cmd head f
  step "$NAME"
  info "config    $PROJECTS_DIR/$PROJECT.conf"
  [ -n "$IN_REPO_CONFIG" ] && ok "in-repo   $IN_REPO_CONFIG (local file overrides it)"

  if [ -d "$REPO/.git" ]; then ok "repo      $REPO"
  else warn "repo      $REPO is not a git repository"; bad=1; fi

  if repo_git rev-parse --verify --quiet "$DEFAULT_BRANCH^{commit}" >/dev/null; then
    ok "branch    $DEFAULT_BRANCH"
  else
    warn "branch    DEFAULT_BRANCH=$DEFAULT_BRANCH does not resolve"; bad=1
  fi

  for f in $COPY_FILES; do
    if [ -e "$REPO/$f" ]; then ok "copy      $f"
    else warn "copy      $f is declared in COPY_FILES but missing from the checkout"; bad=1; fi
  done

  if [ -n "$INSTALL" ]; then
    head="$(cmd_head "$INSTALL")"
    if command -v "$head" >/dev/null 2>&1; then ok "install   $head"
    else warn "install   \`$head\` is not on PATH"; bad=1; fi
  fi

  if [ -n "$COMPOSE_SERVICES" ]; then
    if command -v docker >/dev/null 2>&1; then ok "docker    present"
    else warn "docker    needed for COMPOSE_SERVICES but not on PATH"; bad=1; fi
    if [ -f "$REPO/$COMPOSE_FILE" ]; then ok "compose   $COMPOSE_FILE"
    else warn "compose   $COMPOSE_FILE not found in the checkout"; bad=1; fi
  fi

  if [ -n "$RUNTIME" ]; then
    if command -v "$RUNTIME" >/dev/null 2>&1 || [ "$RUNTIME" = nvm ]; then ok "runtime   $RUNTIME"
    else warn "runtime   RUNTIME=$RUNTIME is not installed"; bad=1; fi
  fi

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    cmd="$(target_field "$t" command)"
    head="$(cmd_head "$cmd")"
    if command -v "$head" >/dev/null 2>&1; then
      ok "target    $t -> $head on port $(target_field "$t" port)"
    else
      warn "target    $t needs \`$head\`, which is not on PATH"; bad=1
    fi
  done <<EOF
$(target_names)
EOF

  if command -v gh >/dev/null 2>&1 && [ -n "$(gh_repo)" ]; then
    ok "github    $(gh_repo)"
  else
    dim "github    no gh or no GitHub remote — pull request badges will be absent"
  fi

  [ "$bad" = 0 ] || return 1
  return 0
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
    port="$(target_port "$t")"
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
  runbranch.sh doctor [<project>]              check a project's config resolves
  runbranch.sh scan [<dir>]                    git repos not yet declared
  runbranch.sh propose <repo>                  guess a config by reading the repo
  runbranch.sh add <repo>                      propose it and write projects/<name>.conf

  machine-readable, used by runbranch.app:
  runbranch.sh projects
  runbranch.sh branches <project>
  runbranch.sh presets <project>
  runbranch.sh favourite <project> on|off      pin it to the top of the sidebar
  runbranch.sh get <project>                   every editable field
  runbranch.sh set <project> <KEY> [value]     rewrite one key in the local conf
  runbranch.sh paths <project> [<ref>]
  runbranch.sh run <p> <ref> <preset> [offset]
                                       offset shifts every port in the run
  runbranch.sh check-ports <p> <preset>
                                       what holds the ports, and a free offset
  runbranch.sh remove <project>        delete a project's config and state, never its repo
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
    get)
      # Every editable field of a project, as key<TAB>value lines. The app reads
      # this rather than parsing .conf itself, so the file stays the engine's
      # business and stays plain shell.
      need_project "${2:-}"
      printf 'NAME\t%s\n'            "$NAME"
      printf 'REPO\t%s\n'            "$REPO"
      printf 'DEFAULT_BRANCH\t%s\n'  "$DEFAULT_BRANCH"
      printf 'SYMBOL\t%s\n'          "${SYMBOL:-shippingbox}"
      printf 'INSTALL\t%s\n'         "$INSTALL"
      printf 'COPY_FILES\t%s\n'      "$COPY_FILES"
      printf 'COMPOSE_SERVICES\t%s\n' "$COMPOSE_SERVICES"
      printf 'COMPOSE_PROJECT\t%s\n' "$COMPOSE_PROJECT"
      printf 'MIGRATE\t%s\n'         "$MIGRATE"
      printf 'SEED\t%s\n'            "$SEED"
      printf 'RUNTIME\t%s\n'         "$RUNTIME"
      printf 'DB_URL_VARS\t%s\n'     "$DB_URL_VARS"
      printf 'ALWAYS\t%s\n'          "$ALWAYS"
      printf 'PRESETS\t%s\n'         "$PRESETS"
      printf 'OPENS_ITSELF\t%s\n'    "$OPENS_ITSELF"
      printf 'PROCFILE\t%s\n'        "$PROCFILE"
      printf 'IN_REPO\t%s\n'         "$IN_REPO_CONFIG"
      # TARGETS last: it is the only multi-line value, so nothing follows it.
      printf 'TARGETS\t%s\n'         "$(printf '%s' "$TARGETS" | tr '\n' '\001')"
      ;;
    set)
      # Rewrite one key in the LOCAL conf. The in-repo .runbranch is never
      # touched: it belongs to the repo and may be someone else's to change.
      [ $# -ge 3 ] || { usage; exit 2; }
      load_project "$2"
      set_project_key "$2" "$3" "${4:-}"
      ;;
    paths)
      # Where things live, so the app never hardcodes the layout.
      #   worktrees <TAB> logs <TAB> config <TAB> repo <TAB> owner/repo [<TAB> worktree-for-ref]
      need_project "${2:-}"
      printf '%s\t%s\t%s\t%s\t%s' "$WORKTREES" "$LOG_DIR" \
        "$PROJECTS_DIR/$PROJECT.conf" "$REPO" "$(gh_repo)"
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
    favourite)
      [ $# -eq 3 ] || { usage; exit 2; }
      set_favourite "$2" "$3"
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
      # An optional fifth argument shifts every port in the run by that much,
      # for when the declared ones are taken by another project.
      [ $# -eq 4 ] || [ $# -eq 5 ] || { usage; exit 2; }
      load_project "$2"
      if [ $# -eq 5 ]; then
        case "$5" in
          ''|*[!0-9]*) die "Port offset must be a number, got \"$5\"." \
            "$SELF run $2 $3 $4 1" ;;
        esac
        PORT_OFFSET="$5"
      fi
      do_run "$3" "$4"
      ;;
    check-ports)
      [ $# -eq 3 ] || { usage; exit 2; }
      load_project "$2"
      local ct
      ct="$(preset_targets "$3")"
      [ -n "$ct" ] || die "Unknown preset \"$3\" for $NAME." "$SELF presets $2"
      check_ports "$ct"
      exit $?
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
    scan)    scan_repos "${2:-$HOME/Development}" ;;
    add)
      # Propose and write it, so the CLI and the app take the same path.
      [ $# -ge 2 ] || { usage; exit 2; }
      add_project "$2"
      ;;
    remove)
      [ $# -ge 2 ] || { usage; exit 2; }
      remove_project "$2"
      ;;
    propose) [ $# -ge 2 ] || { usage; exit 2; }; propose_config "$2" ;;
    doctor)
      if [ $# -ge 2 ]; then load_project "$2"; doctor_project; exit $?; fi
      local n rc=0
      while IFS="$(printf '\t')" read -r n _; do
        [ -n "$n" ] || continue
        ( load_project "$n"; doctor_project ) || rc=1
      done <<EOF
$(list_projects)
EOF
      # Across projects rather than within one, so it belongs here and not in
      # doctor_project.
      report_port_overlaps
      exit "$rc"
      ;;
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
