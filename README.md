<img src="docs/img/mark-256.png" width="84" alt="">

# Runbranch

**Run a branch that isn't the one you're working on.** On a real port, beside
your work, without touching your checkout.

A native macOS app for the thing every developer improvises badly.

---

## Why

A colleague's pull request needs a look. Not a diff — a look. You want to click
the thing. Your options today are all bad:

- **Switch branches in your checkout.** Fails on uncommitted work, or silently
  changes what you were doing.
- **Clone the repo again.** The gitignored `.env` doesn't come with it, so
  everything 401s and it looks like the branch is broken.
- **Keep a second checkout by hand.** You'll forget to update it, and you won't
  remember to delete its `node_modules`.
- **Wait for a preview deploy.** If the stack even has one, and if it can reach
  the data you need.

Runbranch does the version you'd build yourself given an afternoon: a throwaway
git worktree per branch, your gitignored config copied in, dependencies
installed, servers started, and a window that tells you when it's actually up.

**Your checkout is never modified.** No `checkout`, no `stash`, ever.

---

## Install

You need the Xcode command line tools (`xcode-select --install`). Nothing else.

```bash
git clone https://github.com/aosmcleod/runbranch
cd runbranch && ./make-app.sh && open .
```

Drag `Runbranch.app` to the Dock.

The build is ad-hoc signed, not notarised, so the first launch needs
**right-click → Open** rather than a double-click. Notarising it would need an
Apple Developer account; until then that prompt is the honest cost of building
it yourself.

---

## Point it at a repo

You shouldn't have to write a config from nothing. **Add project…** in the
`•••` menu reads the repo — package manager, lockfile, scripts, `Procfile`,
compose services, version pins, which files are gitignored — and proposes one,
then opens it so you can correct the guesses.

A complete project can be four lines:

```bash
NAME="my-app"
REPO="~/code/my-app"
INSTALL="pnpm install --frozen-lockfile"
TARGETS="web:3000:/:pnpm dev"
```

Bigger stacks add only what they need:

```bash
COPY_FILES=".env.local"                    # gitignored, so a worktree lacks it
COMPOSE_SERVICES="postgres valkey"         # brought up and health-waited
MIGRATE="pnpm --filter @app/db db:migrate"
SEED="pnpm --filter @app/db db:seed"       # an empty app isn't worth looking at
RUNTIME="mise"                             # honour the repo's pinned versions
DB_URL_VARS="DATABASE_URL"                 # a database per branch
TARGETS="api:4000:/health:pnpm --filter api dev
web:3000:/:pnpm --filter web dev"
ALWAYS="api"                               # web is useless without it
PRESETS="web=web  full=web,worker"
```

A `Procfile` needs no target list at all — set `PROCFILE=1` and its processes
become your targets.

Full reference: **[docs/config.md](docs/config.md)**. Check any project with
`./runbranch.sh doctor`.

---

## What you get

**A window that tells the truth.** Branches for the selected project, newest
first, each with its pull request state, who wrote it, and what it's actually
about — the PR title, not just the branch name. Remote branches with an open
pull request are listed too, because reviewing someone else's work is the whole
point. Merged and stale branches stay out of the way until you ask.

**A run you can watch.** Press Start and the work happens in front of you:
worktree, install, infrastructure, migrations, seed, servers. It closes itself
when the thing is up and stays put when it isn't — which is the only moment the
log matters.

**Data that doesn't leak between branches.** Two branches with divergent
migrations need not share a database. A project can declare one per run, seeded
from the same source and thrown away with the worktree.

**Status that keeps being true.** Uptime ticks. Health is polled, not assumed.
Processes and ports orphaned by a crash, a sleep or a force quit are found and
reclaimed on next launch — you should never go hunting with `lsof`.

---

## From a shell

The app is a window over `runbranch.sh`. Anything it does, you can do here.

```bash
./runbranch.sh                          # interactive
./runbranch.sh run studio main both
./runbranch.sh stop studio
./runbranch.sh status                   # every project
./runbranch.sh doctor                   # check every config resolves
./runbranch.sh scan                     # repos not yet declared
./runbranch.sh add <repo>               # propose a config and write it
./runbranch.sh cleanup studio           # remove worktrees
```

---

## Principles

- **Never touch the working checkout.** If a feature needs to, the design is wrong.
- **No daemon.** Nothing runs in the background when you're not using it. A run
  you started outlives the window on purpose — close the app, keep the demo —
  and anything orphaned is reclaimed rather than left for you to find.
- **The engine is a shell script you can read.**
- **Fail loudly, with the fix.** Every error names the command that resolves it.
- **Configuration is a file, not a database.** In the repo, versioned, diffable.

---

## It is not

- a process manager — [Overmind](https://github.com/DarthSim/overmind) is better
  at supervising a `Procfile` you already have;
- a worktree browser — [Grovr](https://github.com/j1king/grovr) and
  [Tower](https://www.git-tower.com/) are better at managing worktrees as worktrees;
- an agent orchestrator — [Conductor](https://conductor.build/) and
  [cmux](https://cmux.com/) run parallel coding agents;
- a preview deploy — Vercel and Netlify are better at showing a branch to the
  internet. Runbranch is for private repos, real local data, stacks that need a
  real database, and not waiting on a build queue;
- a sharing tool — what's running is on your machine, for you.

Runbranch does the narrow thing none of them do: **put a branch on a port, and
tell you when it's up.**

---

## Known limits

- **One run per project at a time.** Ports and databases are shared within a
  project, so starting a second stops the first. Different projects use
  different ports and can run at once. `PORTS="stepping"` is declared in the
  config format but not implemented.
- **Per-run databases are Postgres only.**
- **Fork branches aren't listed.** Remote branches on `origin` are; a pull
  request from someone's fork isn't yet.
- **macOS only**, and built against macOS 26 APIs.

---

## Layout

```
runbranch.sh          the engine: git, install, infra, servers. No UI of its own.
app/RunBranch.swift   the front end
projects/*.conf       one file per project
make-app.sh           builds Runbranch.app
make-icons.sh         the graphic set, from assets/mark-source.png
tools/                trim/centre, WebKit render, crop, demo data, screenshots
docs/config.md        every config key
docs/PLAN.md          design notes and roadmap
```

Nothing generated is committed. `Runbranch.app`, `build/` and `demo/` are all
produced by the scripts and gitignored — the repo carries source, one logo
source PNG, and the one mark size the README displays.


## Licence

MIT.
