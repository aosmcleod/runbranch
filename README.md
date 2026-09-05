# project-launcher

A Dock-able runner for any local project, from a **throwaway git worktree**.

```
<your checkout>                                    <- never modified
~/.project-launcher/<project>/worktrees/<branch>/  <- throwaway, one per branch
```

A bash engine with a small SwiftUI front end. No Node, no Homebrew packages,
no Electron, no SPM manifest — just the Xcode command line tools.

---

## Why

Demoing out of your working checkout breaks in the same shape every time:

- Switching branches to show something either fails on uncommitted work, or
  silently changes what the person at the keyboard is looking at.
- Gitignored config (`.env.local` and friends) does not exist in a fresh tree,
  so everything 401s or cannot reach its database. That reads as a broken
  branch when it is a missing file.
- A dev server left running is a concurrent writer on a shared database. Two of
  them plus a test run produced a real deadlock and 29 wasted minutes.

The answer to all three: never touch your checkout, copy the gitignored config
in every time, and be honest about what is already running.

---

## Projects

Each project is a `projects/<name>.conf` — plain bash, sourced by the engine.
Only `NAME`, `REPO` and `TARGETS` are required.

Most projects are "install, run one command, open a URL" and stay four lines:

```bash
NAME="function-ui"
REPO="~/Development/work/function-ui"
INSTALL="npm ci"
TARGETS="docs:5173:/:npm run docs"
```

Function Studio is the complex one, and the reason every other key exists —
three servers, shared Postgres, migrations, a gitignored env file:

```bash
COPY_FILES=".env.local"
COMPOSE_PROJECT="studio"
COMPOSE_SERVICES="postgres valkey"
MIGRATE="pnpm --filter @fs/db db:migrate"
TARGETS="api:4000:/live:pnpm --filter @fs/api dev
web:3000:/:pnpm --filter @fs/web dev
admin:3002:/:pnpm --filter @fs/admin dev"
ALWAYS="api"
PRESETS="web=web admin=admin both=web,admin"
```

Full key reference: [`projects/README.md`](projects/README.md).

---

## Using it

```bash
./make-app.sh          # build the bundle
open .                 # then drag "Project Launcher.app" to the Dock
```

Projects run down the sidebar, each with a spinner when something of its is up.
The main pane is that project's **local** branches, newest first, each with
badges and a last-updated age:

| badge | meaning |
|---|---|
| `default` | the project's default branch — always listed, never filtered |
| `open` / `merged` / `closed` | its pull request, in GitHub's status colours |
| `me` / a first name | who authored the branch tip |
| `ready` | its worktree is built, so this one starts in seconds |

Merged branches and anything older than a week are hidden behind checkboxes.

Pick a branch, pick what to run, press Start. The run happens in a sheet over
the window. It **closes itself when the server comes up** and **stays open when
it does not**, because that is the moment you need the log.

While something is running: that branch carries a spinner, the header names it,
and the buttons become *Open* and *Stop*. Select a different branch and it
becomes *Switch*. Right-click any built branch to remove its worktree.

### From a shell

```bash
./project-launcher.sh                              # interactive
./project-launcher.sh run studio development both
./project-launcher.sh stop studio
./project-launcher.sh status                       # every project
./project-launcher.sh cleanup studio
```

---

## The parts that are not obvious

### Worktrees are detached, never branch checkouts

Git refuses to check out a branch that is already checked out elsewhere — and
demoing the branch you are working on is the common case. A demo runner also
has no business holding a ref it might move.

### `docker compose -p` is pinned

Compose names its project after the directory it runs in, so from a worktree it
would build a **second** stack with its own empty volumes, then collide on any
fixed `container_name`. `COMPOSE_PROJECT` pins it to the one real database.

### "Merged" comes from GitHub, cached

`git branch --merged` looks like it should answer this for free, and for a
merge-commit PR it does. But a **squashed** merge rewrites the commits, so they
are never reachable from the default branch and git can never name it. Verified
against `docs/commit-name-the-ticket`: merged on GitHub, invisible to git.

So the PR map comes from `gh` and is cached per project. Cold: ~1.5s. Warm:
~0.04s, refreshed in the background. The toolbar refresh forces a re-read.

Ownership needs no network: a branch is yours when its tip carries one of your
addresses (`PL_MY_EMAILS` overrides).

### Stopping signals the process group

Each server starts in its own process group. A watcher like `tsx --watch`
respawns its child if you kill only the child; signalling the group takes the
tree down. Anything still holding a port afterwards is only reaped when its
command line points into this project's worktrees — never your own dev server.

### One run per project

Ports and databases are shared within a project, so starting a second run stops
the first. Different projects use different ports and can run at once — the
sidebar shows which.

### PATH, and why the app runs `zsh -lic`

An app launched from the Dock inherits launchd's `PATH`, which has neither
`docker` (`/usr/local/bin`), `pnpm`/`gh` (`/opt/homebrew/bin`), nor `node`
(fnm mints its bin directory per shell session). The bundle runs the engine
through a login+interactive zsh so `PATH` matches your terminal. The script
hardens its own `PATH` as a second layer.

---

## Layout

```
project-launcher.sh        the engine: git, install, infra, servers. No UI of its own.
app/ProjectLauncher.swift  the front end: project sidebar, branch list, run sheet
projects/*.conf            one file per project
make-app.sh                builds Project Launcher.app (swiftc + sips + iconutil)
assets/icon.svg            icon source
```

**Why a compiled front end.** The first version used `osascript` dialogs.
`NSAlert` picks up desktop translucency, shows the interpreter's icon rather
than the app's, and stacks buttons past two. Worse, it cannot show progress, so
starting a run meant handing off to Terminal.app over Apple Events — a
permission the bundle does not hold, which made a failed launch fail *silently*.
The app runs the script as a subprocess and streams it into its own window, so
there is nowhere for a failure to hide.
