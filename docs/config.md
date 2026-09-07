# Configuration reference

One `<name>.conf` per project in `projects/`, plus an optional `.runbranch`
committed to the repo itself.

They are plain bash, sourced by the engine.

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
