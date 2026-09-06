# VISION — the aspirational README

> This is the README the tool should *earn*. It describes the finished thing,
> not the current one. `README.md` stays honest about what exists today; this
> file is the target we build toward, and items move across as they land.
> See [PLAN.md](PLAN.md) for the sequencing.

---

# Greenroom

**Run any branch of any project, on a real port, without touching your checkout.**

A native macOS app for the thing every developer improvises badly: showing
someone a branch that is not the one you are working on.

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

Greenroom does the version of this you would build yourself if you had an
afternoon: a throwaway git worktree per branch, your gitignored config copied
in, dependencies installed, servers started on fixed ports, and a window that
tells you when it is actually up.

**Your checkout is never modified.** No `checkout`, no `stash`, ever.

---

## Install

```bash
brew install --cask greenroom
```

Or build it — you need only the Xcode command line tools:

```bash
git clone https://github.com/aosmcleod/greenroom
cd greenroom && ./make-app.sh && open .
```

---

## A project is a config file

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
RUNTIME="mise"                                 # honour the repo's pinned versions
TARGETS="api:4000:/health:pnpm --filter api dev
web:3000:/:pnpm --filter web dev"
ALWAYS="api"                                   # web is useless without it
PRESETS="web=web  full=web,worker"
```

A `Procfile` needs no config at all — set `PROCFILE=1` and its processes
become your targets.

Full reference: [projects/README.md](../projects/README.md).

---

## What you get

**A window that tells the truth.** Branches for the selected project, newest
first, each with its pull request state, who wrote it, and what it is actually
about — the PR title, not just the branch name. Merged and stale branches are
out of the way until you ask.

**A run you can watch.** Press Start and the work happens in front of you:
worktree, install, infrastructure, migrations, servers. It closes itself when
the thing is up, and stays put when it is not — which is the only moment the
log matters.

**Status that keeps being true.** Uptime ticks. Health is polled, not assumed.
Ports are buttons. A menu bar item tells you what is running when the window
is closed.

**Housekeeping that is not your problem.** Worktrees are listed with their
size, and the ones whose branch has since merged are offered up for deletion.

---

## Principles

- **Never touch the working checkout.** If a feature needs to, the design is wrong.
- **No daemon.** Nothing runs when you are not using it.
- **The engine is a shell script you can read.** The app is a window over
  `greenroom.sh`; anything the app does, you can do in a terminal.
- **Fail loudly, with the fix.** Every error names the command that resolves it.
- **Configuration is a file, not a database.** Version it, diff it, share it.

---

## It is not

- a process manager — [Overmind](https://github.com/DarthSim/overmind) is
  better at supervising a Procfile you already have;
- a worktree browser — [Grovr](https://github.com/j1king/grovr) and
  [Tower](https://www.git-tower.com/) are better at managing worktrees as
  worktrees;
- an agent orchestrator — [Conductor](https://conductor.build/) and
  [cmux](https://cmux.com/) run parallel coding agents.

Greenroom does the narrow thing none of them do: **put a branch on a port, and
tell you when it is up.**

---

## Licence

MIT.
