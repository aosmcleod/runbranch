# VISION — the aspirational README

> This is the README the tool should *earn*. It describes the finished thing,
> not the current one. `README.md` stays honest about what exists today; this
> file is the target we build toward, and items move across as they land.
> See [PLAN.md](PLAN.md) for the sequencing.

---

# runbranch

**Run a branch that isn't the one you're working on.** On a real port, beside
your work, without touching your checkout.

A native macOS app for the thing every developer improvises badly.

![screenshot placeholder](docs/screenshot.png)

---

## Why

You want to demo a branch. Your options today are all bad:

- **Switch branches in your checkout** — fails on uncommitted work, or silently
  changes what you were doing.
- **Clone the repo again** — and now the gitignored `.env` is missing, so
  everything 401s and it looks like the branch is broken.
- **Keep a second checkout by hand** — which you will forget to update, and
  whose `node_modules` you will not remember to delete.
- **Wait for a preview deploy** — if the stack even has one, and if it can
  reach the data you need.

runbranch does the version you would build yourself if you had an afternoon: a
throwaway git worktree per branch, your gitignored config copied in,
dependencies installed, servers started, and a window that tells you when it is
actually up.

**Your checkout is never modified.** No `checkout`, no `stash`, ever.

## Run more than one

Branches are worth comparing. A refactor next to `main`. Two competing fixes.
Three pull requests in a review session.

Every run gets its own worktree and its own ports. Projects whose ports are
baked into their config — an OAuth origin, a CORS allowlist, an API URL the
client was built with — say so, and run one at a time; everything else steps up
from the port you named and the window tells you which is which. Your own dev
server is never in the fight.

---

## Install

```bash
brew install --cask runbranch
```

Or build it — you need only the Xcode command line tools:

```bash
git clone https://github.com/aosmcleod/runbranch
cd runbranch && ./make-app.sh && open .
```

---

## Point it at a repo

You should not have to write the config from nothing. runbranch reads the
repo — package manager, lockfile, scripts, `Procfile`, `compose.yaml`, version
pins, what is gitignored — and **proposes** one. You correct it and commit it.

The result is a `.runbranch` file that lives in the repo. Version it, diff it,
review it in a pull request.

A complete project can be four lines:

```bash
NAME="my-app"
REPO="~/code/my-app"
INSTALL="pnpm install --frozen-lockfile"
TARGETS="web:3000:/:pnpm dev"
```

That is a complete project. Point Greenroom at a repo and it will offer to
write this for you by reading what is already there.

Bigger stacks add only what they need:

```bash
COPY_FILES=".env.local"                        # gitignored, so a worktree lacks it
COMPOSE_SERVICES="postgres valkey"             # brought up and health-waited
MIGRATE="pnpm --filter @app/db db:migrate"
SEED="pnpm --filter @app/db db:seed"           # an empty app is not worth looking at
RUNTIME="mise"                                 # honour the repo's pinned versions
PORTS="fixed"                                  # this stack bakes its origins in
TARGETS="api:4000:/health:pnpm --filter api dev
web:3000:/:pnpm --filter web dev"
ALWAYS="api"                                   # web is useless without it
PRESETS="web=web  full=web,worker"
```

A `Procfile` needs no config at all — set `PROCFILE=1` and its processes
become your targets.

Full reference: [config.md](config.md).

`COPY_FILES` names things that are gitignored, so they are not in a fresh
clone either. An in-repo config makes the *shape* of a project shareable; it
does not distribute your secrets, and nothing here pretends otherwise.

---

## What you get

**A window that tells the truth.** Branches for the selected project, newest
first, each with its pull request state, who wrote it, and what it is actually
about — the PR title, not just the branch name. Remote branches you have never
fetched are listed too, forks included; selecting one fetches it. Merged and
stale branches stay out of the way until you ask.

**A run you can watch.** Press Start and the work happens in front of you:
worktree, install, infrastructure, migrations, servers. It closes itself when
the thing is up, and stays put when it is not — which is the only moment the
log matters.

**Status that keeps being true.** Uptime ticks. Health is polled, not assumed.
Ports are buttons. A menu bar item tells you what is running when the window
is closed.

**Data that does not leak between branches.** Two branches with divergent
migrations need not share a database. A project can declare one per run, seeded
from the same source and thrown away with the worktree.

**Housekeeping that is not your problem.** Worktrees are listed with their
size, and the ones whose branch has since merged are offered up for deletion.
Processes and ports orphaned by a crash, a sleep or a force quit are found and
reclaimed on next launch — you should never have to go hunting with `lsof`.

---

## Principles

- **Never touch the working checkout.** If a feature needs to, the design is wrong.
- **No daemon.** Nothing runs in the background when you are not using it. A
  run you started outlives the window on purpose — close the app, keep the
  demo — and anything orphaned is reclaimed rather than left for you to find.
- **The engine is a shell script you can read.** The app is a window over
  `greenroom.sh`; anything the app does, you can do in a terminal.
- **Fail loudly, with the fix.** Every error names the command that resolves it.
- **Configuration is a file, not a database.** In the repo, versioned,
  diffable, shared.

The tradeoff in that last one: a config is sourced as shell, so it can run
arbitrary code. That is the price of an engine you can read, and it is the same
trust you already extend to a repo's `postinstall` scripts. Treat a config from
a repo you do not trust the way you would treat that repo.

---

## It is not

- a process manager — [Overmind](https://github.com/DarthSim/overmind) is
  better at supervising a Procfile you already have;
- a worktree browser — [Grovr](https://github.com/j1king/grovr) and
  [Tower](https://www.git-tower.com/) are better at managing worktrees as
  worktrees;
- an agent orchestrator — [Conductor](https://conductor.build/) and
  [cmux](https://cmux.com/) run parallel coding agents;
- a preview deploy — Vercel and Netlify are better at showing a branch to the
  internet. runbranch is for private repos, real local data, stacks that need a
  real database, and not waiting on a build queue;
- a sharing tool — what is running is on your machine, for you.

runbranch does the narrow thing none of them do: **put a branch on a port, and
tell you when it is up.**

---

## Licence

GPL-3.0.
