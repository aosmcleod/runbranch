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

Only the first three colons in a `TARGETS` line are separators, so commands
may contain colons.
