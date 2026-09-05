# frankly-launcher

A Dock-able runner for the Frankly (Function Studio) demo.

It runs the demo from a **throwaway git worktree**, so demoing never competes
with whatever you are editing in `~/Development/work/Studio`.

```
~/Development/work/Studio                    <- your checkout, never touched
~/Development/work/.frankly-demo/<branch>/   <- throwaway worktree, one per branch
```

Bash and `osascript` only. No Node, no Homebrew packages, no Electron.

---

## Why this exists

Running the demo out of the working checkout breaks in the same shape every
time:

- Switching branches to demo something either fails on uncommitted work, or
  silently changes what the person at the keyboard is looking at.
- `.env.local` is gitignored, so a fresh branch or worktree starts with no
  config and everything 401s or cannot reach Postgres. That reads as a broken
  branch when it is a missing file.
- A dev server left running is a concurrent Postgres writer. Two of them plus a
  test run produced a real deadlock and 29 wasted minutes.

The launcher's answer to all three: never touch your checkout, copy
`.env.local` in every time, and allow exactly one demo at a time.

---

## First-run setup

**Prerequisites** (the launcher checks each one and names the fix if it is
missing):

| Need | Get it |
|---|---|
| Node 24 | see `.nvmrc` in Studio |
| pnpm 9 | `corepack enable` |
| Docker Desktop, running | `open -a Docker` |
| A `~/.npmrc` GitHub Packages token | `gh auth refresh -h github.com -s read:packages` then `node scripts/ensure-npmrc.mjs` |
| HeroUI Pro credentials | `npx heroui-pro login` |
| `~/Development/work/Studio/.env.local` | `cd ~/Development/work/Studio && pnpm bootstrap` |

Two of those are worth expanding.

**The `read:packages` token.** `@function-point/fxui` comes from GitHub
Packages. Studio's root `.npmrc` maps the scope but deliberately carries no
auth line, so the token has to be in `~/.npmrc` — and a default `gh auth login`
does **not** grant `read:packages`. Without it, `pnpm install` 401s. The
launcher checks this before the install rather than after, so you get the fix
instead of a raw pnpm error.

**HeroUI Pro.** Without `HEROUI_AUTH_TOKEN` or `~/.heroui`, `@heroui-pro/react`
installs as a *stub*. The install still succeeds — the missing types only
surface later at typecheck, or as a blank render. The launcher warns and lets
you decide.

**Build the app bundle:**

```bash
cd ~/Development/work/frankly-launcher && ./make-app.sh
```

Then drag `Frankly Launcher.app` to the Dock.

The bundle does not contain a copy of the script — it calls
`frankly-launcher.sh` where it sits in this repo, so edits take effect with no
rebuild. If you ever move the repo, re-run `make-app.sh`.

---

## Using it

Click the Dock icon. You get native pickers:

1. **Which branch.** Recently-demoed branches first, then local branches, then
   the 25 most recently updated remote branches. Anything older is reachable
   through *Type a branch name...*; *Refresh the list from origin* runs a
   `git fetch` when you ask for one. The branch currently checked out in Studio
   is marked, and so is any branch whose worktree is already built.
2. **What to run.** `web` (port 3000), `admin` (port 3002), or both. The api
   (port 4000) always starts — web and admin are useless without it.

From there the launcher prepares the worktree, installs, brings up Postgres and
Valkey, migrates if needed, starts the servers, and opens the browser once they
answer. Launched from the Dock, that phase runs in a Terminal window so you can
watch it — the first install on a cold pnpm store takes a few minutes, and a
silent spinner is how a launcher gets mistaken for a hung one.

While a demo is running, clicking the icon offers: open in browser, stop,
switch branch, show logs, remove old worktrees.

### From a shell

```bash
./frankly-launcher.sh                    # same pickers, output stays in your terminal
./frankly-launcher.sh run development both
./frankly-launcher.sh stop
./frankly-launcher.sh status             # exit 0 if a demo is running
./frankly-launcher.sh cleanup
```

---

## The constraints, and why

### One demo at a time

**Postgres is shared.** It cannot be isolated per worktree without more
machinery than this deserves, so the launcher allows exactly one demo and
offers to stop a running one rather than starting a second.

This is also why it refuses to start when something already holds port 3000,
3002 or 4000. If that something is *your own* dev server in Studio, the
launcher names the process and the port and leaves it alone — stopping it is
your call, not the tool's.

### Migrations mutate the one shared database

There is a single local database and every branch shares it. The launcher
compares the branch's Drizzle journal against the migrations the database has
actually applied:

- **Branch ahead** — it runs `pnpm --filter @fs/db db:migrate` and says so.
- **Database ahead** — another branch already migrated it. Those changes do not
  roll back and this branch's code has never seen them, so the launcher warns
  and makes you confirm.

Clean slate, which **destroys all local data**:

```bash
docker compose -p studio -f ~/Development/work/.frankly-demo/<branch>/docker-compose.yml down -v
```

Then re-run the launcher and re-seed with `pnpm seed:account`.

A per-branch database (`CREATE DATABASE studio_<branch>` plus a `DATABASE_URL`
override) would remove this whole class of problem. It is a deliberate
non-goal for now — it is a bigger change than the pain currently justifies.

### Sign-in only works on `localhost`

Clerk dev instances accept exactly **one** primary frontend origin, and the
customer web claims `localhost:3000`. So `admin.studio.test:3002` and
`portal.studio.test:3001` cannot also be Clerk origins on the same instance.
The launcher only ever opens `localhost` URLs. The friendly `studio.test`
hostnames still resolve, but admin and portal sign-in break on them.

---

## What it does to your Studio checkout

Effectively nothing. It **never** runs `git checkout`, `git stash`, or anything
else that touches Studio's working tree or index. What it does do:

| Action | Why it is safe |
|---|---|
| Reads refs (`for-each-ref`, `rev-parse`) | read-only |
| Copies `.env.local` | read-only on the source |
| `git worktree add / remove / prune / list` | `.git` metadata plus the throwaway directory; Studio's working tree is untouched |
| `git fetch --prune origin` | **only when you pick "Refresh the list from origin"**; updates remote-tracking refs, touches nothing else |

Worktrees are created **detached** at the branch tip, never as a checkout of
the branch itself. That is deliberate: git refuses to check out a branch that
is already checked out elsewhere, and demoing the branch you are working on is
the common case. A demo runner also has no business holding a branch ref it
might move.

---

## Cleanup

Worktrees accumulate and each carries its own `node_modules` — about **1.2 GB**
each. *Remove old worktrees* in the menu (or `./frankly-launcher.sh cleanup`)
lists them with sizes and lets you select several at once. The worktree backing
a running demo is skipped; stop it first.

---

## Stopping cleanly

Each server is started in its own process group, and stopping signals the
**group**, not the pid. This matters: the api runs under `tsx --watch`, which
respawns its node child if you kill only the child.

If a port is still held after a stop, the launcher only reaps the process when
its command line points into `.frankly-demo`. Anything else it reports and
leaves alone.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `401` from `npm.pkg.github.com` during install | `gh auth refresh -h github.com -s read:packages`, then `node scripts/ensure-npmrc.mjs` in the worktree |
| `ERR_PNPM_OUTDATED_LOCKFILE` | The branch's lockfile does not match its `package.json`. `cd <worktree> && pnpm install`, then re-run the launcher |
| Blank or unstyled UI | HeroUI Pro installed as a stub. `npx heroui-pro login`, then delete the worktree and let it rebuild |
| Everything 401s, or Postgres is unreachable | `.env.local` did not make it in. Confirm it exists in Studio; the launcher re-copies it on every run |
| Port busy, and it is not the launcher's | Something else owns it — the launcher names the pid. `kill <pid>` if you meant to |
| A server never comes up | Logs are in `~/Development/work/.frankly-demo/logs/`. Run it in the foreground: `cd <worktree> && pnpm --filter @fs/web dev` |

---

## Layout

```
frankly-launcher.sh   the whole thing
make-app.sh           builds Frankly Launcher.app (sips + iconutil, both built into macOS)
assets/icon.svg       icon source
Frankly Launcher.app  the Dock bundle
```

State lives outside the repo, in `~/Development/work/.frankly-demo/`:
`.state` (the running demo), `.recent` (branch MRU), `logs/`, `meta/`.
