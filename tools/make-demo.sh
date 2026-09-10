#!/usr/bin/env bash
#
# Build a self-contained demo: fictional repos, fictional branches, fictional
# people. Nothing here touches or references a real project.
#
# The demo is not a mock-up — the repos are real git repos and the running
# target is a real server, so Start genuinely works and health genuinely goes
# green. Faking those would have meant a screenshot showing a state the app
# cannot actually reach.
#
#   ./tools/make-demo.sh          build it
#   ./tools/make-demo.sh --clean  remove it
#
# Then run the app against it:
#   RB_PROJECTS_DIR=demo/projects RB_HOME=demo/state RB_MY_EMAILS=dana@example.com \
#     Runbranch.app/Contents/MacOS/RunBranch

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$REPO/demo"

if [ "${1:-}" = --clean ]; then rm -rf "$DEMO"; echo "removed $DEMO"; exit 0; fi

rm -rf "$DEMO"
mkdir -p "$DEMO/repos" "$DEMO/projects" "$DEMO/state"

ME="dana@example.com"

# Cut a branch from the trunk, so its ahead/behind counts mean something.
#
# `commit` alone would branch from wherever HEAD happens to be, which chains
# every branch off the last one: each is then one ahead of its neighbour and
# none is behind the trunk at all, so the divergence column has nothing to
# say. Real branches are cut from the trunk and fall behind it.
#
# branch_from <repo> <trunk> <branch>
branch_from() { git -C "$1" checkout -q "$2" && git -C "$1" checkout -q -B "$3"; }

# Land a branch on the trunk without a pull request ever recording it, which is
# the case only the commit graph can answer.
#
# merge_back <repo> <trunk> <branch> <author-name> <author-email> <days-ago>
merge_back() {
  local r="$1" trunk="$2" br="$3" an="$4" ae="$5" ago="$6" when
  when="$(date -u -v-"${ago}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')"
  git -C "$r" checkout -q "$trunk"
  GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" \
  GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae" \
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$r" merge -q --no-ff -m "merge: $br" "$br"
}

# commit <repo> <branch> <author-name> <author-email> <days-ago> <subject>
commit() {
  local r="$1" br="$2" an="$3" ae="$4" ago="$5" subj="$6"
  local when; when="$(date -u -v-"${ago}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')"
  git -C "$r" checkout -q -B "$br" >/dev/null 2>&1
  printf '%s\n' "$subj" >> "$r/CHANGELOG.md"
  git -C "$r" add -A
  GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" \
  GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae" \
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$r" commit -q -m "$subj"
}

newrepo() {
  local name="$1" default="$2"; local r="$DEMO/repos/$name"
  mkdir -p "$r"; git -C "$r" init -q -b "$default"
  git -C "$r" config user.name "Dana Okonkwo"; git -C "$r" config user.email "$ME"
  printf '# %s\n' "$name" > "$r/README.md"
  commit "$r" "$default" "Dana Okonkwo" "$ME" 20 "chore: initial commit"
  printf '%s' "$r"
}

echo "==> repos"

# 1. The one that actually runs. A real static server on a real port.
R1="$(newrepo northwind-web main)"
mkdir -p "$R1/public"
cat > "$R1/public/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Northwind</title>
<style>body{font:16px/1.6 -apple-system,sans-serif;margin:0;display:grid;place-items:center;
height:100vh;background:#111318;color:#e8eaf0}h1{font-weight:600}</style>
<h1>Northwind — demo branch</h1>
HTML
commit "$R1" main "Dana Okonkwo" "$ME" 12 "feat(web): landing page shell"

branch_from "$R1" main "feat/checkout-summary"
commit "$R1" "feat/checkout-summary"  "Dana Okonkwo" "$ME"        0 "feat(checkout): show tax and shipping before payment"
commit "$R1" "feat/checkout-summary"  "Dana Okonkwo" "$ME"        0 "feat(checkout): itemise the tax lines"
commit "$R1" "feat/checkout-summary"  "Dana Okonkwo" "$ME"        0 "test(checkout): cover the zero-shipping case"
branch_from "$R1" main "fix/cart-quantity-race"
commit "$R1" "fix/cart-quantity-race" "Priya Raman" "priya@example.com" 1 "fix(cart): debounce quantity updates so the last write wins"
branch_from "$R1" main "feat/saved-addresses"
commit "$R1" "feat/saved-addresses"   "Dana Okonkwo" "$ME"        2 "feat(account): let customers save more than one address"
commit "$R1" "feat/saved-addresses"   "Dana Okonkwo" "$ME"        2 "feat(account): default address per customer"
branch_from "$R1" main "chore/bump-deps"
commit "$R1" "chore/bump-deps"        "Marco Silva" "marco@example.com" 9 "chore: bump minor dependencies"
# Merged by hand and never opened as a pull request, so nothing but the commit
# graph can tell you it is spent. Hidden until Show merged is on, which is the
# point of it being here.
branch_from "$R1" main "chore/tidy-imports"
commit "$R1" "chore/tidy-imports"     "Aisha Bello" "aisha@example.com" 3 "chore: sort imports"
merge_back "$R1" main "chore/tidy-imports" "Aisha Bello" "aisha@example.com" 12

# The trunk moves on after the branches are cut, which is the whole point of a
# "behind" count. Dated the same day as the commit before it, so the rows' ages
# stay put and only the divergence changes.
commit "$R1" main "Aisha Bello" "aisha@example.com" 12 "fix(build): pin the toolchain"
commit "$R1" main "Dana Okonkwo" "$ME" 12 "chore: drop the unused polyfill"
git -C "$R1" checkout -q main

R2="$(newrepo aperture-api main)"
commit "$R2" main "Dana Okonkwo" "$ME" 14 "feat(api): health and readiness probes"
branch_from "$R2" main "feat/webhook-retries"
commit "$R2" "feat/webhook-retries"   "Dana Okonkwo" "$ME"        0 "feat(webhooks): retry with exponential backoff and a dead-letter queue"
branch_from "$R2" main "fix/timezone-drift"
commit "$R2" "fix/timezone-drift"     "Priya Raman" "priya@example.com" 3 "fix(reports): compute day boundaries in the tenant's timezone"
branch_from "$R2" main "perf/batch-inserts"
commit "$R2" "perf/batch-inserts"     "Marco Silva" "marco@example.com" 5 "perf(ingest): batch inserts, 40k rows/s to 180k"
git -C "$R2" checkout -q main
commit "$R2" main "Marco Silva" "marco@example.com" 14 "refactor(api): one error envelope"
git -C "$R2" checkout -q main

R3="$(newrepo lumen-ui main)"
commit "$R3" main "Dana Okonkwo" "$ME" 16 "docs: component gallery"
branch_from "$R3" main "feat/date-picker"
commit "$R3" "feat/date-picker"       "Dana Okonkwo" "$ME"        1 "feat(date-picker): keyboard navigation and range selection"
commit "$R3" "feat/date-picker"       "Dana Okonkwo" "$ME"        1 "fix(date-picker): clamp the range to the month"
branch_from "$R3" main "fix/focus-ring-contrast"
commit "$R3" "fix/focus-ring-contrast" "Aisha Bello" "aisha@example.com" 4 "fix(a11y): focus ring now passes contrast on tinted surfaces"
git -C "$R3" checkout -q main
commit "$R3" main "Aisha Bello" "aisha@example.com" 16 "docs: token reference"
git -C "$R3" checkout -q main

R4="$(newrepo ledger-service main)"
commit "$R4" main "Dana Okonkwo" "$ME" 18 "feat: double-entry primitives"
branch_from "$R4" main "feat/reconciliation"
commit "$R4" "feat/reconciliation"    "Marco Silva" "marco@example.com" 2 "feat(recon): match statement lines against postings"
git -C "$R4" checkout -q main
commit "$R4" main "Dana Okonkwo" "$ME" 18 "feat: posting rules"
git -C "$R4" checkout -q main

echo "==> projects"
cat > "$DEMO/projects/northwind-web.conf" <<CONF
NAME="Northwind Web"
REPO="$DEMO/repos/northwind-web"
DEFAULT_BRANCH="main"
# A real server, so Start actually works and health actually goes green.
TARGETS="web:4173:/:python3 -m http.server 4173 --directory public"
SYMBOL="cart"
CONF
cat > "$DEMO/projects/aperture-api.conf" <<CONF
NAME="Aperture API"
REPO="$DEMO/repos/aperture-api"
DEFAULT_BRANCH="main"
TARGETS="api:4174:/health:python3 -m http.server 4174"
SYMBOL="server.rack"
CONF
cat > "$DEMO/projects/lumen-ui.conf" <<CONF
NAME="Lumen UI"
REPO="$DEMO/repos/lumen-ui"
DEFAULT_BRANCH="main"
# Deliberately the same port as the api above. Framework defaults really do
# collide — three projects on the author's machine all want 5173 — and the
# Ports sheet's overlap section has nothing to show without one.
TARGETS="docs:4174:/:python3 -m http.server {port}"
SYMBOL="paintpalette"
CONF
cat > "$DEMO/projects/ledger-service.conf" <<CONF
NAME="Ledger Service"
REPO="$DEMO/repos/ledger-service"
DEFAULT_BRANCH="main"
TARGETS="svc:4176:/:python3 -m http.server 4176"
SYMBOL="building.columns"
CONF

# Pull request data the engine would normally get from gh. Same TSV shape:
#   branch  state  number  title  author
echo "==> pull requests"
for p in northwind-web aperture-api lumen-ui ledger-service; do mkdir -p "$DEMO/state/$p"; done
cat > "$DEMO/state/northwind-web/prcache" <<'TSV'
feat/checkout-summary	OPEN	412	Show tax and shipping before payment
fix/cart-quantity-race	OPEN	410	Debounce cart quantity updates
feat/saved-addresses	OPEN	407	Multiple saved addresses per customer
chore/bump-deps	MERGED	399	Bump minor dependencies
TSV
cat > "$DEMO/state/aperture-api/prcache" <<'TSV'
feat/webhook-retries	OPEN	288	Retry webhooks with backoff and a dead-letter queue
fix/timezone-drift	OPEN	285	Compute day boundaries in the tenant timezone
perf/batch-inserts	MERGED	279	Batch ingest inserts
TSV
cat > "$DEMO/state/lumen-ui/prcache" <<'TSV'
feat/date-picker	OPEN	96	Date picker keyboard navigation and ranges
fix/focus-ring-contrast	OPEN	94	Focus ring contrast on tinted surfaces
TSV
cat > "$DEMO/state/ledger-service/prcache" <<'TSV'
feat/reconciliation	OPEN	51	Match statement lines against postings
TSV

echo
echo "Demo built in $DEMO"
echo "Run it with:"
echo "  RB_PROJECTS_DIR=$DEMO/projects RB_HOME=$DEMO/state RB_MY_EMAILS=$ME \\"
echo "    '$REPO/Runbranch.app/Contents/MacOS/RunBranch'"
