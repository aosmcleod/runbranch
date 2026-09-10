# Configuration reference

One `<name>.conf` per project, plus an optional `.runbranch` committed to the
repo itself.

They are plain bash, sourced by the engine.

## Where they live

| you are running | `.conf` files are read from |
|---|---|
| `runbranch.sh` from a checkout | `projects/`, beside the script |
| Runbranch.app | `~/.runbranch/projects/` |
| anything, with `RB_PROJECTS_DIR` set | that directory, which wins over both |

The app does not keep them inside its own bundle. Installing a new version
replaces the bundle whole, so anything kept there is destroyed by the next
update — which is what used to happen. `~/.runbranch/` is the directory that
survives an install, and it is where the per-project state has always lived.

`runbranch.sh projects-dir` prints the one in effect.

Only `NAME`, `REPO` and `TARGETS` are required. Everything else exists because
one project needed it — most projects are "install, run one command, open a
URL" and should stay four lines long.

| key | required | meaning |
|---|---|---|
| `NAME` | yes | display name |
| `REPO` | yes | path to the git checkout (`~` is expanded) |
| `TARGETS` | yes | one per line: `name:port:healthpath:command` |
| `DEFAULT_BRANCH` | no | pinned to the top of the list, never filtered out (default `main`) |
| `INSTALL` | no | run in the worktree before starting |
| `COPY_FILES` | no | gitignored files copied from the checkout on every run |
| `COMPOSE_PROJECT` | no | pins `docker compose -p`; see `studio.conf` for why this matters |
| `COMPOSE_SERVICES` | no | services brought up with `--wait` |
| `COMPOSE_FILE` | no | default `docker-compose.yml` |
| `MIGRATE` | no | run after infra is healthy |
| `ALWAYS` | no | targets started regardless of preset |
| `PRESETS` | no | `label=target,target` — defaults to one per target, plus `all` |
| `OPENS_ITSELF` | no | `1` when the dev server opens a browser itself (vite `--open`) |
| `SEED` | no | run after migrations — an empty app is not worth looking at |
| `RUNTIME` | no | `mise` / `fnm` / `asdf` / `nvm` — activated **inside the worktree**, so the repo's own pin is honoured |
| `PROCFILE` | no | `1` derives targets from the repo's `Procfile`. Ports are assigned foreman-style from `PORT_BASE` (default 5000, +100 each) and exported as `PORT` |
| `PORT_OFFSET` | no | shifts every port this project declares by this much, and rewrites `{port}` in its commands to match. `0` (default) uses the declared ports. Framework defaults collide — three projects here all want 5173 — and this is how two of them run at once without editing the number in both the target and the command. It moves the whole set together, so a project declaring 3000 and 3001 keeps them adjacent |
| `PORT_BASE` | no | first port assigned when `PROCFILE=1` |
| `PORTS` | no | `fixed` (default) or `stepping`. Stepping is not implemented yet — a stack that bakes its origins into config (an OAuth origin, a CORS allowlist, an API URL the client was built with) must stay fixed |
| `SYMBOL` | no | SF Symbol for the sidebar |
| `DB_URL_VARS` | no | variables carrying the connection string, e.g. `"DATABASE_URL DATABASE_READ_URL"`. Each run gets its own database, created and migrated from scratch and dropped with the worktree. **Postgres only** |
| `DB_TEMPLATE` | no | create from this database instead of empty — faster than migrating and seeding |
| `DB_ADMIN_USER` | no | who creates it (default: the user in the URL) |

Only the first three colons in a `TARGETS` line are separators, so commands
may contain colons.

You should not have to write one of these from nothing:

```bash
./runbranch.sh scan               # git repos not yet declared
./runbranch.sh propose <repo>     # guess a config, print it
./runbranch.sh add <repo>         # guess it and write projects/<name>.conf
```

`propose` reads the lockfile for the package manager, `package.json` for the
script to run (`dev`, `start`, `docs`, `storybook`, `serve` — whichever exists),
the script's own flags for the port, `.nvmrc` / `.tool-versions` / `mise.toml`
for the toolchain, the compose file's `services:` block for what to bring up,
and which env files are gitignored. Where the repo says nothing, it leaves an
obvious blank rather than a plausible command that fails minutes later.

In the app it is **Add project…** in the `•••` menu, which then opens the file
so you can correct the guesses.

### Environment

| variable | effect |
|---|---|
| `RB_PROJECTS_DIR` | where the `.conf` files live |
| `RB_HOME` | where worktrees, logs, state and the PR cache live |
| `RB_MY_EMAILS` | space-separated addresses that count as yours |
| `RB_PR_TTL` | seconds before the pull request cache is refreshed (default 900) |
| `RB_NO_OPEN` | set to anything to stop a run opening a browser — for tests and scripts |
| `RB_OTHER_LIMIT` | how many of everyone else's branches to list (default 80) |

### Favourites

Pinning a project puts it above the others in the sidebar. It is stored in
`~/.runbranch/favourites`, not in the project's config, because pinning is a
personal preference rather than a property of the project the way a port or an
install command is — and a `.runbranch` committed to a repo should not carry
one person's sidebar order.

### Filtering, in the app

The filter menu hides by default: merged branches, anything older than a week,
and remote branches without an open pull request. It can also show **only your
branches**, judged by the addresses in `RB_MY_EMAILS`.

The default branch and whatever is currently running are never filtered out —
hiding the thing on screen would be worse than a wide filter.

### Per-run databases

Two branches with divergent migrations sharing one database is the oldest
problem here: migrating for one silently rewrites the other, and nothing rolls
it back. `DB_URL_VARS` gives each branch its own instead.

The database is named `<base>_rb_<branch>`, created when the run starts,
migrated and seeded from scratch, and dropped when the worktree is removed —
not when the run stops, so restarting is cheap. The worktree's copies of
`COPY_FILES` are rewritten to point at it, rather than relying on an exported
variable, because dotenv loaders disagree about which wins and a file you can
read is easier to trust than a precedence rule.

Run `./runbranch.sh doctor` to check every project's config resolves — that
each declared command exists, the branch resolves, `COPY_FILES` are present,
and the compose file is where it says. All of those otherwise surface minutes
into a run, as a failure that looks like the branch's fault.

---

## When two projects want the same port

Framework defaults collide. Three projects on this machine all want 5173 and
two want 3000, so they cannot run at the same time.

```bash
./runbranch.sh overlaps                  # ports claimed by more than one project
./runbranch.sh suggest-offset <project>  # the smallest shift that frees its ports
./runbranch.sh set <project> PORT_OFFSET 1
```

`doctor` reports the same overlaps in prose. In the app they are listed at the
bottom of the **Ports** sheet, with a **Move…** menu that picks the number for
you — which one moves is a real choice, since one of them is usually the
project you think of as owning the port.

A suggestion has to clear every port the project declares at once, and it
accounts for whatever is already listening — including a dev server Runbranch
did not start, since running alongside your own is the point.

Deliberately not surfaced on the project rows themselves. Nothing is wrong
until you try to run the second one, and a warning on every project that merely
*might* clash is a warning nobody reads.

## Keeping the config in the repo

A project can carry its own `.runbranch` file. The local `projects/<name>.conf`
still wins, so one person can change a port or add a preset without changing
what everyone else runs:

```
<repo>/.runbranch          the shape of the project — reviewable in a PR
projects/<name>.conf       NAME and REPO, plus anything you want different
```

`COPY_FILES` names gitignored files, which are not in a clone either. An
in-repo config makes the *shape* of a project shareable; it does not
distribute your secrets, and nothing here pretends otherwise.

## A note on trust

A config is sourced as shell, so it can run arbitrary code. That is the price
of an engine you can read, and it is the same trust you already extend to a
repo's `postinstall` scripts. Treat a config from a repo you do not trust the
way you would treat that repo.

## Worktree runs and in-place runs

By default a run happens in a throwaway worktree: a separate copy of the
repository at one commit, under `RB_HOME`. Everything in this reference
applies to it.

`--in-place` runs in the checkout instead, and is accepted only for the branch
the checkout is on — git will not check a branch out twice. It starts the
declared `TARGETS` and manages their ports, health and logs. It deliberately
ignores everything that writes:

| Key | In place |
|---|---|
| `INSTALL` | not run — it writes into a directory you are working in, and can move a lockfile |
| `COPY_FILES` | not copied — they are already there |
| `DB_URL_VARS` | no per-run database — the mechanism rewrites `COPY_FILES`, which here would mean editing your real config |
| `MIGRATE`, `SEED` | not run, for the same reason: they act on whatever database the checkout already points at |
| `COMPOSE_SERVICES` | left alone — whatever the checkout is pointed at is what it gets |

So an in-place run is the servers, and nothing else. If a project needs any of
the above to be usable, run it from a worktree.

## Worktrees, and what they cost

A run gets a worktree under `RB_HOME/<project>/worktrees/<slug>`, and it stays
there after the run stops. Nothing prunes it automatically.

That is a choice rather than an oversight. The expensive part of a run is the
install, and keeping the worktree is what makes the next run of that branch
fast. Deleting it on stop would trade a few hundred megabytes for minutes on
every re-run.

The cost is real though — a full checkout plus its dependencies, commonly
several hundred megabytes each:

| Command | What it does |
|---|---|
| `runbranch.sh disk` | every worktree across every project: size, the ref it was made from, and whether it is running, `idle`, or `gone` |
| `runbranch.sh cleanup <project>` | lists that project's worktrees with sizes and removes the ones you pick. Refuses the running one |
| `runbranch.sh prune-gone <project>` | removes every worktree whose ref no longer exists, without asking. `gone` and not `merged`: a squash-merge leaves a branch looking unmerged, so that heuristic would either miss the common case or delete work |
| `runbranch.sh remove-worktree <project> <ref>` | removes exactly one |
| `runbranch.sh remove <project>` | the config and everything under `RB_HOME` for it. Never the repository |

`gone` means the ref no longer resolves in the repository — a deleted branch —
so nothing will ever want that worktree again. Those are the safe ones to
remove first.

Deliberately absent is any notion of "merged". A squash-merge leaves the branch
looking unmerged to `git branch --merged`, so a prune based on that would
eventually delete a worktree for a branch still in use.
