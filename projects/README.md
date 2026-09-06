# Project definitions

One `<name>.conf` per project. They are plain bash, sourced by the engine.

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

Run `./runbranch.sh doctor` to check every project's config resolves — that
each declared command exists, the branch resolves, `COPY_FILES` are present,
and the compose file is where it says. All of those otherwise surface minutes
into a run, as a failure that looks like the branch's fault.
