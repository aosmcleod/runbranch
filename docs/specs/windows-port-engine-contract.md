# Runbranch engine contract (runbranch.sh v1.5.1)

This is the spec a Go engine has to meet to be a drop-in replacement for `runbranch.sh`. It comes from `runbranch.sh` (2675 lines), `app/Engine.swift`, `app/Model.swift`, every call site in `app/*.swift`, `tests/engine.sh`, `tests/ui.sh`, `tools/screenshot.sh`, `tools/make-demo.sh`, and `docs/config.md`.

Conventions used below:

- `\t` means TAB and `\n` means LF.
- Every machine-readable output is UTF-8 with LF line endings. The Swift side splits on `"\n"`, so **a CRLF would leave a `\r` stuck to the last field**.
- "die" means the shared failure path in section 0.3: output to stderr, then exit 1.
- "(quirk)" marks something the bash engine really does that is probably unintended. Each one needs a decision: match it or fix it.

---

## 0. Cross-cutting behaviour

### 0.1 Process model

- The app runs the engine directly as `<engine> <args...>`, never through a shell (`Engine.process`). stdin is `/dev/null`.
- The environment is the user's login-shell environment (`zsh -lic 'env -0'`, read once with a 5 s deadline), overlaid with the app's own variables. The app's own values win, except `PATH`, which comes from the login shell. If `PATH` is empty, the app falls back to `own PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
- The engine path is resolved in this order:
  1. `$RB_ENGINE`, if it is executable.
  2. `Contents/Resources/runbranch.sh` in the bundle, if it is executable.
  3. That same bundle path anyway.
- The bash script runs under `set -uo pipefail`, not `-e`.
- Every invocation first calls `harden_path` and then `migrate_bundle_projects` (see 4 and 5.1). That includes `help`.

### 0.2 TTY detection

`HAVE_TTY` is 1 when **stdout** is a terminal (`[ -t 1 ]`). The app never gives it one. `HAVE_TTY` controls three things:

- **Colour.** ANSI codes are emitted only when `HAVE_TTY=1` and `NO_COLOR` is unset. The codes are `\033[2m` dim, `31` red, `32` green, `33` yellow, `34` blue, `1` bold and `0` off. The app strips `\x1B\[[0-9;]*m` anyway.
- **`ask`.** Without a TTY it never reads anything. With default-yes it prints `        <question>  -> yes` and returns yes. With default-no it prints `        <question>  -> no (assuming the cautious answer)` and returns no.
- **Output format of `ports` and `disk`.** Both print TSV without a TTY and a human table with one (see 1.x).
- **`menu`.** It refuses to run without a TTY.

### 0.3 Human output helpers (stdout)

| helper | exact format |
|---|---|
| `step` | `\n==> <text>\n`, coloured `<BLU>==><OFF> <BLD>text<OFF>` |
| `ok` | `    ok   <text>\n` (4 spaces, `ok`, 3 spaces) |
| `info` | `        <text>\n` (8 spaces) |
| `dim` | `        <text>\n` (8 spaces, dim colour) |
| `warn` | `    warn <text>\n` |

**die** writes to **stderr** and then exits 1:

```
printf '\n%s%s FAILED %s %s\n' BLD RED OFF "<msg>"                # without a TTY: "\n FAILED  <msg>\n"
[fix] printf '\n%sFix:%s\n\n    %s\n\n' BLD OFF "<fix>"           # "\nFix:\n\n    <fix>\n\n"
```

`<msg>` and `<fix>` can span several lines. **The app depends on this shape in two places:**

- `Engine.failure()` (used by `favourite`, `kill-port`, `prune-gone`, and `stop` for other owners). It **discards stdout** and reads stderr only, and only when the exit status is non-zero. It deletes every `"FAILED"` substring, trims whitespace, and shows what is left, `Fix:` block included. An empty result becomes `"<cmd> failed, with nothing to say why."`.
- `Engine.set()` returns stderr exactly as written. `ProjectEditor` trims it and shows **only the first line**, which is `FAILED  <msg first line>`. **The first line of stderr therefore has to carry the message.**

### 0.4 Exit codes

| code | meaning |
|---|---|
| 0 | success |
| 1 | any `die`. Also, by design: `check-ports` found a conflict, `status` found nothing running, `suggest-offset` found no free range, `doctor` found problems |
| 2 | usage error. `usage` goes to **stdout** first. Triggered by a missing required arg, a wrong arg count, or an unknown subcommand |

### 0.5 Usage text (stdout; also `-h`, `--help`, `help`, all exit 0)

This is verbatim from `usage()`, except that `$PROJECTS_DIR` and `$RB_HOME` are expanded:

```
Runbranch — run any local project from a throwaway git worktree.

  runbranch.sh                          interactive
  runbranch.sh run <project> <ref> <preset>
  runbranch.sh stop <project>
  runbranch.sh status [<project>]
  runbranch.sh cleanup <project>
  runbranch.sh doctor [<project>]              check a project's config resolves
  runbranch.sh scan [<dir>]                    git repos not yet declared
  runbranch.sh propose <repo>                  guess a config by reading the repo
  runbranch.sh add <repo>                      propose it and write projects/<name>.conf

  machine-readable, used by runbranch.app:
  runbranch.sh projects
  runbranch.sh branches <project>
  runbranch.sh presets <project>
  runbranch.sh favourite <project> on|off      pin it to the top of the sidebar
  runbranch.sh get <project>                   every editable field
  runbranch.sh set <project> <KEY> [value]     rewrite one key in the local conf
  runbranch.sh paths <project> [<ref>]
  runbranch.sh run <p> <ref> <preset> [offset] [--in-place]
                                       offset shifts every port in the run;
                                       --in-place uses the checkout, not a worktree
  runbranch.sh check-ports <p> <preset>
                                       what holds the ports, and a free offset
  runbranch.sh update <project>        re-check-out the ref at its tip and restart
  runbranch.sh prune-gone <project>    remove worktrees whose ref no longer exists
  runbranch.sh overlaps                ports claimed by more than one project
  runbranch.sh suggest-offset <p>      the smallest PORT_OFFSET that frees its ports
  runbranch.sh disk                    every worktree, its size, and whether it is in use
  runbranch.sh ports                   every declared port, and what is on it
  runbranch.sh kill-port <pid>         end a port holder, if it belongs to a project
  runbranch.sh remove <project>        delete a project's config and state, never its repo
  runbranch.sh reclaim [<project>]     reclaim ports and clear state a crash left
  runbranch.sh state <project>
  runbranch.sh remove-worktree <project> <ref>
  runbranch.sh refresh <project>

Projects   : <PROJECTS_DIR>
State      : <RB_HOME>/<project>/
```

### 0.6 How a project argument is loaded

There are two guard styles:

- `need_project "${2:-}"` exits 2 with usage when the arg is empty, then calls `load_project`. Used by `branches`, `get`, `paths`, `presets`, `state`, `refresh`, `update`, `prune-gone`, `suggest-offset`, `stop` and `cleanup`.
- An explicit `$#` check, then `load_project` directly. Used by `set`, `reclaim <p>`, `remove-worktree`, `run`, `check-ports`, `status <p>` and `doctor <p>`.

`load_project` dies on any of these. Each message is shown here with the text that follows `Fix:`.

| condition | message | fix |
|---|---|---|
| no conf file | `No project called "<name>".` | `ls <PROJECTS_DIR>    # or add <name>.conf there` |
| syntax error | `<name>.conf has a syntax error:\n  <bash -n output with the "<file>: " prefix stripped>\n\nA config is shell, so an unclosed quote or stray backtick stops it being read.` | `open -t '<file>'` |
| no REPO | `<name>.conf sets no REPO.` | `edit <file>` |
| REPO not a repo | `<NAME>: <REPO> is not a git repository.` | `edit <file>` |
| PROCFILE with no processes | `<name>.conf sets PROCFILE=1 but <REPO>/Procfile has no processes.` | `cat <REPO>/Procfile` |
| no TARGETS | `<name>.conf declares no TARGETS.` | `edit <file>` |

Tests pin the syntax-error text. It has to contain `syntax error` and `line 1`, and it must not contain `sets no REPO`.

---

## 1. Subcommands

The app parses stdout with `components(separatedBy: "\t")`, so **empty fields are preserved and count toward the field total**.

### 1.1 `projects` (app)

- **Args:** none.
- **stdout:** one line per loadable project, in glob order of `<PROJECTS_DIR>/*.conf`. Bash sorts that by locale collation (quirk: Go's byte order can differ for mixed case). A project that fails to load is **silently omitted**.

```
<id>\t<NAME>\t<REPO expanded>\t<stateFileExists 0|1>\t<SYMBOL or "shippingbox">\t<favourite 0|1>\n
```

- **Swift parsing (`Project(tsv:)`):**
  - Needs `f.count >= 3`.
  - `id=f[0]`, `name=f[1]`, `repo=f[2]`.
  - `symbol = f.count >= 5 && !f[4].isEmpty ? f[4] : "shippingbox"`.
  - `favourite = f.count >= 6 && f[5] == "1"`.
  - `f[3]` is unused. It means "the state file exists", not "is alive".
- **Exit:** 0. It prints nothing when the directory is missing.

### 1.2 `projects-dir` (app)

- **stdout:** `<PROJECTS_DIR>\n`. Exit 0.
- The app resolves this **once per process**, trims it, and falls back to `~/.runbranch/projects` if the output is empty.

### 1.3 `branches <project>` (app)

- **stdout:** 15 tab-separated fields per branch. Tests assert `NF == 15`.
- **Order:** every local branch (`refs/heads`, newest committer date first), then every remote-tracking branch under `refs/remotes/origin` (same sort). Remote rows skip `origin`, `origin/HEAD`, any empty short name, and any branch whose short name already appeared as a local row.

| # | field | how it is derived |
|---|---|---|
| 1 | ref | `refname:short`; remote rows keep the `origin/` prefix |
| 2 | age | `d = now - committer_ts`. If `d<3600`: `int(d/60)"m"`. If `<86400`: `int(d/3600)"h"`. If `<2592000`: `int(d/86400)"d"`. Otherwise `int(d/2592000)"mo"` |
| 3 | ts | committer date as unix seconds |
| 4 | owner | `me` when mine, otherwise the author name's first space-separated word |
| 5 | mine | `1` when any space-separated entry of `MY_EMAILS` is a **substring** of `%(authoremail)`, which includes angle brackets (`<x@y>`); otherwise `0` |
| 6 | pr | `OPEN`, `MERGED` or `CLOSED` from the PR cache, keyed by branch name without `origin/`; `NONE` when absent |
| 7 | ready | `1` when `<WORKTREES>/<slug>` exists, with `slug = ref` and every `[^A-Za-z0-9._-]` turned into `-`. (Quirk: `origin/` is **not** stripped here, unlike `slug_for`, so remote rows are practically never ready. Digest-suffixed slugs are ignored.) |
| 8 | isDefault | `1` iff `ref == DEFAULT_BRANCH` |
| 9 | isCurrent | `1` iff `ref == git -C REPO rev-parse --abbrev-ref HEAD` |
| 10 | prNumber | from the PR cache, else empty |
| 11 | subject | PR title from the cache, else the tip commit subject. A tab in the subject truncates it, because it was the last git field |
| 12 | isRemote | `0` for local rows, `1` for remote rows |
| 13 | checkedOutAt | path of a *foreign* worktree holding this branch, else empty (see below) |
| 14 | ahead | commits the ref has that the trunk does not. **Empty** when git < 2.41 |
| 15 | behind | commits the trunk has that the ref does not. **Empty** when git < 2.41 |

- **Trunk:** `refs/remotes/origin/<DEFAULT_BRANCH>` if it resolves, else `refs/heads/<DEFAULT_BRANCH>`, else no counts at all. The atom `%(ahead-behind:<trunk>)` is probed first with `for-each-ref --count=1` against the trunk itself. If the probe fails, both columns are empty.
- **Foreign worktrees:** from `git worktree list --porcelain`. Take each `branch` entry with `refs/heads/` stripped, and drop any whose path equals `REPO` or starts with `WORKTREES`. The bash implementation packs them as space-separated `ref|path` pairs. (Quirk: a path containing a space breaks the lookup.)
- **Side effect:** `ensure_pr_cache` (section 5.6). When no cache exists this **blocks** on `gh`.
- **Swift parsing (`Branch(tsv:)`):**
  - Needs `f.count >= 9`.
  - `ref=f[0]`, `age=f[1]`, `timestamp=Int(f[2]) ?? 0`, `owner=f[3]`.
  - `mine = f[4]=="1"`.
  - `pr = PRState(raw:f[5])`, where only `OPEN`, `MERGED` and `CLOSED` are recognised.
  - `ready = f[6]=="1"`, `isDefault = f[7]=="1"`, `isCurrent = f[8]=="1"`.
  - Optional: `prNumber=f[9]`, `subject=f[10]`, `isRemote = f[11]=="1"`, `checkedOutAt=f[12]`.
  - `ahead = f.count>13 ? Int(f[13]) : nil` and `behind = f.count>14 ? Int(f[14]) : nil`. **An empty string must stay "no answer" (nil), not become 0**, because `ahead == 0` means "subsumed, safe to delete".
  - `display` strips `origin/` from remote refs.
- **Exit:** 0, or 1 if the project fails to load.

### 1.4 `presets <project>` (app)

- **stdout:** one name per line.
  - If `PRESETS` is set: split it on whitespace and print each word's text before the first `=`.
  - Otherwise: every target name, plus `all` when there is more than one target.
- Swift keeps the non-empty lines.
- **How a preset expands (used by `run` and `check-ports`):**
  - Take the comma list of the first `PRESETS` word whose label matches.
  - If there is none, `all` means every target, and **any other name expands to itself as a single target**. (Quirk: an unknown preset never triggers the "Unknown preset" die. The run fails later with "exited immediately".)
  - `ALWAYS` targets are then prepended, skipping any already in the list. The result is space-separated and trimmed.

### 1.5 `paths <project> [<ref>]` (app)

- **stdout:** one line.

```
<WORKTREES>\t<LOG_DIR>\t<PROJECTS_DIR>/<id>.conf\t<REPO>\t<gh owner/repo or empty>[\t<worktree_path(ref)>]\n
```

- Tests expect `NF=5`, or `NF=6` when a ref is given.
- Swift reads only the first line:
  - `[1]` logs, for the log viewer and "reveal logs".
  - `[2]` config file, to open or reveal it.
  - `[4]` GitHub slug, to build `https://github.com/<slug>/pull/<n>`.
  - `[5]` worktree for a ref, to open it in an editor or reveal it; requires `count >= 6`.
- `worktree_path` applies the collision-aware slug from 5.4 but creates nothing.
- **gh slug:** take `git config --get remote.origin.url`, drop everything up to `github.com[:/]`, drop a trailing `.git`, and keep the result only if it contains `/`.

### 1.6 `state <project>` (app, polled)

**Idle, with nothing adopted.** stdout is exactly `idle\n`.

**Running (a live pid recorded in the state file):**

```
run\t<REF>\t<PRESET>\t<STARTED>\t<EPOCH>\t<WORKTREE>\t<IN_PLACE 0|1>\n
behind\t<N>\n
[switched\t<branch>\n]              # only for an in-place run whose checkout is now on a different branch
target\t<name>\t<effective port>\t<health path>\t<pid or 0>\t<alive 0|1>\n   # one per state TARGETS entry, zipped with PIDS
```

- `STARTED` is `YYYY-MM-DD HH:MM:SS` in local time. `EPOCH` is unix seconds.
- The port is the **effective** port: declared plus the `PORT_OFFSET` restored from the state file. Tests pin this.
- `alive` is `kill -0 pid`.
- **behind** is 0 for in-place runs, when the worktree is missing, or when the ref is gone. Otherwise it is `git rev-list --count <worktree HEAD>..<ref^{commit}>`.
- **switched** is emitted only when `IN_PLACE=1` and the checkout's current branch is non-empty and not `REF`.

**Adopted.** This applies when no run of ours is live but one of the project's own target ports is held by a process attributed to this project with kind `outside` (see 5.8):

```
run\t<current branch of REPO>\t\t<ps lstart of first holder>\t<epoch parsed from lstart or 0>\t<REPO>\t1\t1\n
target\t<name>\t<effective port>\t<health>\t<pid>\t1\n       # one per held port
```

- There is no `behind` line.
- `lstart` looks like `Thu Sep 24 10:00:00 2026`. Bash parses it with BSD `date -j -f '%a %b %d %T %Y'`.

**Swift parsing (`RunState(output:)`):**

- `run`, when `f.count>=6`: `ref=f[1]`, `preset=f[2]`, `started=f[3]`, `epoch=Double(f[4])`, `worktree=f[5]`, `inPlace = f.count>6 && f[6]=="1"`, `adopted = f.count>7 && f[7]=="1"`.
- `behind`, when `f.count>=2`: `Int(f[1])`.
- `switched`, when `f.count>=2`.
- `target`, when `f.count>=6`: `name=f[1]`, `port=Int(f[2])`, `health=f[3]`, `pid=Int(f[4])`, `alive = f[5]=="1"`.
- Unknown lines are ignored, and **that is the extension mechanism**: new data goes on new line types.
- The app polls `http://localhost:<port><health or "/">` every 5 s (3 s timeout). Status `< 500` counts as healthy.

**Exit:** always 0, except 1 if the project fails to load.

### 1.7 `get <project>` (app)

**stdout:** `KEY\tVALUE\n` lines in this exact order:

1. `NAME`
2. `REPO` (expanded)
3. `DEFAULT_BRANCH`
4. `SYMBOL` (default `shippingbox`)
5. `INSTALL`
6. `COPY_FILES`
7. `COMPOSE_SERVICES`
8. `COMPOSE_PROJECT`
9. `MIGRATE`
10. `SEED`
11. `RUNTIME`
12. `DB_URL_VARS`
13. `ALWAYS`
14. `PRESETS`
15. `OPENS_ITSELF`
16. `PROCFILE`
17. `IN_REPO` (the path of the in-repo `.runbranch`, or empty)
18. `TARGETS`, **always last**, with every `\n` replaced by `\x01`.

Values are the merged result of the in-repo file and the local file.

Swift splits each line on `\t` and needs `count >= 2`. The value is `parts[1...]` rejoined with `\t`, then `\x01` is turned back into `\n`.

**Not emitted:** `PORT_OFFSET`, `COMPOSE_FILE`, `PORT_BASE`, `PORTS`, `DB_TEMPLATE`, `DB_ADMIN_USER`. (Quirk and app bug: `ProjectEditor` binds a `PORT_OFFSET` field, so it always loads empty even when the conf sets it.)

A multi-line value in any key other than `TARGETS` would break the line framing.

### 1.8 `set <project> <KEY> [value]` (app, via `Engine.set`)

- **Args:** `$# >= 3`, otherwise usage and exit 2. The value defaults to empty.
- The project is loaded first, and must load.
- **Wire format:** the app replaces `\n` in the value with `\x01`; the engine turns `\x01` back into `\n`.
- **Key check:** the bash glob `[A-Z][A-Z_]*`, meaning at least 2 characters, first `A-Z`, second `A-Z` or `_`, then anything. Otherwise die `"<KEY>" is not a config key.`, fix `runbranch.sh get <name>`.
- **Algorithm** (Python rewrite of the **local** conf only; the in-repo `.runbranch` is never touched):
  1. `cp file file.bak`.
  2. Split the file on `\n`.
  3. For each line matching `^KEY=`, emit `KEY="<value>"` in its place. **The value is not escaped** (quirk: a `"` breaks the file and it is reverted; `$(...)` would run on every later load).
  4. **Skip continuation lines:** if the text after `KEY=` starts with `"` and the rest (or `"` when the rest is empty) does not match `"\s*$`, keep skipping lines until one matches `"\s*$`, and skip that line too.
  5. Every matching line is replaced, so duplicates each get the new value.
  6. If no line matched, strip trailing empty lines, append `KEY="<value>"`, and append a final empty element so the file ends with `\n`.
  7. Write the result joined with `\n`.
- **Comments on other lines survive.** Tests assert the `^#` count is unchanged. A trailing comment on the **replaced** line is dropped.
- **Quirk, and data loss:** a line like `RUNTIME="mise"   # pinned in the repo` fails the "closed quote" test, so the rewrite **eats every following line up to and including the next line ending in `"`**. `propose` writes exactly these trailing comments, on `RUNTIME` and `COPY_FILES`. The Go version should parse properly rather than copy this.
- **Verify:** reload the project in a subshell. If it fails, restore `.bak` and die `Setting <KEY> produced a config that will not load; reverted.` If the rewrite itself fails: `Could not rewrite <KEY>; the config is unchanged.` If there is no conf: `No config at <file>.`
- **stdout on success:** `    ok   <KEY> set in <file>`, and `.bak` is removed.
- **Exit:** 0 or 1.
- Tests pin these behaviours:
  - a simple key is written;
  - comments are kept;
  - an absent key is appended;
  - a multi-line `TARGETS` survives (`presets` gives 3 lines and `doctor` passes);
  - `set REPO ""` leaves the file byte-identical;
  - `set twin PORT_OFFSET N` works although `PORT_OFFSET` is not in `get`.

### 1.9 `favourite <project> on|off` (app, via `failure`)

- **Args:** exactly 3, otherwise usage and exit 2.
- **The project is not validated.** Any value other than `on` means off.
- **Effect:** `mkdir -p`, touch `<RB_HOME>/favourites`, drop every exact-line match of the name, append the name if on, write via tmp file and `mv`.
- **stdout:** `    ok   <name> added to favourites` or `... removed from favourites`.
- **Exit:** 0.
- Idempotent: tests check that the name appears exactly once after two `on` calls.

### 1.10 `check-ports <project> <preset>` (app, via `capture`, before every start)

- **Args:** exactly 3, otherwise usage and exit 2. An unknown or empty preset dies `Unknown preset "<p>" for <NAME>.`
- **Per target of the expanded preset**, with its effective port held by a listener:
  1. Attribute the holder (5.8).
  2. **Skip it** when `owner == this project && kind == ours`, because `run` stops its own run first.
  3. Otherwise print:

```
<target>\t<effective port>\t<owner or empty>\t<ours|outside|unknown>\t<pid>\t<explicit|env>\n
```

  `explicit` means the command contains `{port}`; `env` means it does not.

- **If any line was printed**, append `OFFSET\t<n>\n` and **exit 1**.
  - `n` is the smallest `try` in 1..200 such that no *declared* port plus `try` is held by any current listener.
  - If none is found, `n` is 201.
  - The search looks only at listeners, not at other projects' declarations.
- **No conflicts:** no output, exit 0.
- **Swift parsing (`PortConflict.parse`):**
  - `OFFSET` with `count >= 2` sets `freeOffset = Int(f[1]) ?? 1`.
  - Other lines need `count >= 6`, with `Int(f[1])` and `Int(f[4])` parseable: `target=f[0]`, `port`, `owner=f[2]`, `kind = Kind(rawValue:f[3]) ?? .unknown`, `pid`, `move = Move(rawValue:f[5]) ?? .env`.
  - The result is nil when there are no clashes.
  - The app treats `code != 0 && parse != nil` as a conflict and shows the resolver. Anything else, including a die with no stdout, goes straight to `run`.
- **Resolver actions:**
  - **Take over:** `kill-port <pid>` for each `outside` clash, then `run`.
  - **Switch:** `stop <owner>` for each distinct `ours` owner, then `run`.
  - **Shift:** `run ... <freeOffset>`.
- (Quirk: the displayed port is *effective*, but `OFFSET` is relative to the *declared* port, and `run`'s offset **replaces** the conf `PORT_OFFSET`. `Ports.swift:141` shows `clash.port + freeOffset`, which is wrong when the conf offset is not 0.)
- (Test staleness: `tests/engine.sh:464` asserts the output contains `"\t1"` for "overridable". The field is now `explicit` or `env`, so the test passes only by accident, when a pid starts with 1.)

### 1.11 `kill-port <pid>` (app, via `failure`)

- **Args:** exactly 2.
- A non-numeric pid dies `Not a process id: "<pid>".` (test-pinned).
- If `ps -p pid` fails, print `        pid <pid> is already gone.` and exit 0.
- Attribute the pid (5.8). If the owner is empty or the kind is `unknown`, die `Refusing to end pid <pid> — it does not belong to a project Runbranch knows about.\n\n<ps desc>`, fix `kill <pid>      # if that is really what you want`. Test-pinned substring: `does not belong to a project`; pid 1 must survive.
- **`ours` holders are also killed.** The message says "started outside Runbranch" either way.
- **Kill sequence:**
  1. Print `        ending <owner> (pid <pid>), started outside Runbranch`.
  2. Send `kill -TERM pid`, to the pid only, not the group.
  3. Wait up to 10 s, checking `kill -0` each second.
  4. If it is still alive, die `pid <pid> did not stop within 10s.`, fix `kill -9 <pid>`.
  5. Otherwise print `    ok   stopped` and exit 0.

### 1.12 `ports` (app, polled every 30 s)

- **Without a TTY**, one line per target of every loadable project:

```
<project>\t<target>\t<effective port>\t<free|ours|outside>\t<owner>\t<kind>\t<pid>\t<what>\n
```

- A free port prints `n\tt\tport\tfree\t\t\t\t`, which is 8 fields, 5 of them empty.
- The effective port here uses `load_state`, so a running project reports its **run's** offset. Otherwise the conf `PORT_OFFSET` applies.
- `ours` requires `kind == ours && owner == project`; everything else held is `outside`.
- `what` is the first 70 characters of `ps -o pid=,command=` with leading spaces stripped, so it **includes the pid**.
- **Swift (`PortRow.parse`):** needs `count >= 8` and `Int(f[2])`. `project=f[0]`, `target=f[1]`, `port`, `state=f[3]`, `owner=f[4]`, `pid=Int(f[6]) ?? 0`, `what=f[7]`. `f[5]` (kind) is unused.
- **With a TTY:** a `\nPorts\n\n` header, then rows formatted `"  %-16s %-8s %-6s %-8s %s"` (the last column is `what`, blank when free), then a blank line.
- **Exit:** 0.

### 1.13 `overlaps` (app)

- **stdout:** `<port>\t<proj> <proj>...\n` for every *effective* declared port (conf `PORT_OFFSET` applied, no state) that more than one project claims.
- Pairs are de-duplicated with `sort -u` on `port\tproject`, then sorted numerically by port. The order of projects within a line is `sort -u` lexical order.
- **Swift:** needs `count >= 2` and `Int(f[0])`. The projects are `f[1]` split on space, kept only when there are more than 1.
- Test: `awk NF` on the 4321 line is 2.

### 1.14 `suggest-offset <project>` (app)

- **stdout:** `<n>\n`. Exit 0, or **exit 1 printing `0`** when nothing is free within 0..200.
- `n` is the smallest `try` in **0**..200 such that no *declared* port (no offset) of this project plus `try` is in either of two sets:
  - the effective declared ports of every *other* project;
  - the port of every current listener. (Quirk: this includes this project's own live run, so a running project never gets 0.)
- A project with no ports prints `0` and exits 0.
- **Swift:** `code == 0 ? Int(trimmed) : nil`. The app treats `0` as "does not need moving" and a value above 0 as a write via `set <p> PORT_OFFSET <n>`.

### 1.15 `disk` (app, on demand; slow)

- **Without a TTY:** `<project>\t<slug>\t<ref or "?">\t<KiB from du -sk, default 0>\t<running|gone|idle>\n` for every directory in `<WORKTREES>/*` of every loadable project.
  - `running` means the directory equals `S_WORKTREE` of a live run.
  - `gone` means the meta ref exists but no longer resolves (`rev-parse --verify --quiet <ref>^{commit}` fails).
  - `idle` covers everything else, including a missing meta file.
- **Swift (`DiskRow.parse`):** needs `count >= 5`: `project`, `slug`, `ref`, `kb=Int(f[3])`, `state`.
- **With a TTY:** the header `Worktrees on disk`, rows as `"  %-14s %-30s %7.0f MB  %s"`, a totals line `"\n  %d worktrees, %.1f GB total, %.1f GB not in use\n"` (or `  Nothing on disk yet.`), then `\n  Remove them with: <SELF> cleanup <project>\n\n`.

### 1.16 `prune-gone <project>` (app, via `failure`)

- Skips the running worktree and any directory without a meta ref.
- For each directory whose ref no longer resolves:
  1. Run `git worktree remove --force`, falling back to a leashed `rm -rf`.
  2. Remove the meta file.
  3. Print `    ok   removed <slug> — <ref> no longer exists` (test-pinned).
- Then runs `git worktree prune`.
- If nothing was removed it prints `        Nothing to prune — every worktree's ref still exists.`
- **Always ends with `pruned\t<count>\n`** (test-pinned).
- With no worktrees directory at all it prints `        No worktrees on disk.`, **without a `pruned` line**.
- **Exit:** 0.

### 1.17 `scan [<dir>]` (app)

- **Default dir:** `$HOME/Development`. The app passes its own default, from `RB_SCAN_ROOT` or `~/Development`.
- A missing dir dies `<root> does not exist.`
- **Candidates:** `find <root> -maxdepth 3 -type d -name .git -not -path "*/node_modules/*"`, with the `/.git` suffix stripped, sorted. Only `.git` **directories** count; worktrees and submodules have a `.git` file.
- **Name:** basename, lower-cased, with every `[^a-z0-9._-]` turned into `-`.
- **Skipped** when `<PROJECTS_DIR>/<name>.conf` exists, or when any conf contains the literal `"<path>"`. (Quirk: `add` writes `REPO` in `~/...` form, so the path check misses it and only the name check protects.)
- **stdout:** `<name>\t<path>\n`. Swift needs `count >= 2` and a non-empty `f[0]`.

### 1.18 `add <repo>` (app)

- **Args:** `$# >= 2`. A trailing `/` is stripped.
- `<repo>/.git` must be a **directory**, otherwise die `<dir> is not a git repository.`
- The name is normalised as in `scan`. If `<PROJECTS_DIR>/<name>.conf` exists, die `<name> is already declared.`
- `mkdir -p PROJECTS_DIR`, then write the `propose` output to the conf. If that fails, remove the file and die.
- **stdout:** `<name>\t<conf path>\n`.
- **Swift:** needs `code == 0`; takes the first line; needs `count >= 2`, giving `(name, file)`. The app then selects the project and opens the file.

### 1.19 `propose <repo>` (shell and tests; the logic behind `add`)

Prints a conf to stdout in this exact sequence. `[]` marks a conditional line.

```
# Proposed by `runbranch propose` on YYYY-MM-DD.
# Every value is a guess read out of the repo. Correct anything wrong,
# then check it with: runbranch.sh doctor <name>
<blank>
NAME="<basename, original case>"
REPO="<path with ^$HOME replaced by ~>"
DEFAULT_BRANCH="<origin/HEAD short name without origin/, else current branch, else main>"
[INSTALL="<install>"]
[RUNTIME="<mise|asdf|fnm>"          # pinned in the repo]
[COPY_FILES="<list>"    # gitignored, so a worktree lacks it]
[COMPOSE_FILE="<f>"  COMPOSE_PROJECT="<name>"  COMPOSE_SERVICES="<svcs>"]   # three lines, only if services were found
```

Then one of two blocks:

- **Procfile present:** `\n# This repo has a Procfile, which already lists what to run.\nPROCFILE=1`.
- **Otherwise:** `\n# port guessed from <the dev script|the framework default>`, followed by either:
  - `TARGETS="<key>:<port>:/:<pm> run <key>"`, or
  - two comment lines (`# Nothing in this repo says how to run it -- no lockfile, no` / `# package.json script. Fill this in, then: runbranch.sh doctor <name>`) and `TARGETS="dev:<port>:/:REPLACE-ME"`.

It closes with `[OPENS_ITSELF=1        # the dev server opens a browser itself]` when the script contains `--open`, then `SYMBOL="shippingbox"`.

**Detection rules:**

- **Lockfile to package manager and install command**, first match wins:

| lockfile | pm | install |
|---|---|---|
| `pnpm-lock.yaml` | pnpm | `pnpm install --frozen-lockfile` |
| `bun.lockb` | bun | `bun install --frozen-lockfile` |
| `yarn.lock` | yarn | `yarn install --immutable` |
| `package-lock.json` | npm | `npm ci` |
| `Gemfile.lock` | bundle | `bundle install` |
| `uv.lock` | uv | `uv sync` |
| `poetry.lock` | poetry | `poetry install` |
| `Cargo.lock` | cargo | (none) |
| nothing | (none) | (none) |

- **Script key:** the first of `dev start docs storybook serve` whose `package.json` `scripts[key]` is non-empty (read via `python3`). With none, the key is `dev`. The dev command exists only when both the script and a pm exist.
- **Port:** the first match of `sed -E 's/.*(--port[= ]|(^| )-p )([0-9]{2,5}).*/\3/'`. Failing that, the framework default is decided by substring of the script: `next` 3000, `vite` 5173, `astro` 4321, `remix` 3000, `nuxt` 3000, `storybook` 6006, `rails` or `puma` 3000, `django` or `manage.py` 8000. Failing that, 3000.
- **Runtime:** `mise.toml` or `.mise.toml` gives `mise`; else `.tool-versions` gives `asdf`; else `.nvmrc` gives `fnm`.
- **COPY_FILES:** whichever of `.env.local .env .env.development` exist **and** are gitignored (`git check-ignore -q`).
- **Compose:** the first of `docker-compose.yml compose.yaml compose.yml docker-compose.yaml` found. Services are the 2-space-indented keys under the top-level `services:` block whose names start with one of `postgres postgresql mysql mariadb redis valkey mongo mongodb elasticsearch rabbitmq`.

Tests require the output to contain `DEFAULT_BRANCH="main"`, `REPO=`, and `REPLACE-ME` (for the lockfile-less fixture).

### 1.20 `run <project> <ref> <preset> [offset] [--in-place]` (app, streamed)

- **Args:** `$# >= 4`. The trailing args may come in any order:
  - `--in-place` sets `IN_PLACE=1`;
  - an all-digit arg sets `PORT_OFFSET` (the last one wins, and it **replaces** the conf value);
  - anything else, including an empty string, dies `Unexpected argument "<x>".`
- **Sequence (`do_run`):**
  1. Expand the preset. If it comes out empty, die `Unknown preset ...`.
  2. Print a header line `<NAME> — <ref> (<preset>)`, bold on a TTY.
  3. Run `harden_path` and `require_cmd git`.
  4. If a run is live: `    warn <NAME> already has <S_REF> running.`, then `ask "Stop it and start this one?"` (non-TTY answer: yes), then a full `stop_run` with output. (Quirk: the `load_state` call inside `demo_running` **overwrites the requested `PORT_OFFSET` and `IN_PLACE` with the previous run's values** whenever a state file exists, even a stale one. So "Run on N" or `--in-place` while switching within a project is silently lost. Recommend Go keeps the requested values.)
  5. `ensure_ports_free` (1.20.1).
  6. **In-place:** the ref must equal the current branch, otherwise die `<REPO> has <cur> checked out, not <ref>.`, fix `cd <REPO> && git switch <ref>      # or run it from a worktree instead` (test-pinned: `has main checked out`, `git switch`). Then print `step "In place   <REPO>"`, `info "the checkout as it stands, uncommitted work included"`, `warn "no install, no copied files, no per-run database"`, and call `start_run` with `WORKTREE=REPO`. **Install, copy, compose, per-run database, migrate and seed are all skipped.**
  7. **Worktree mode:** `prepare_worktree`, `install_deps`, `bring_up_infra`, `setup_run_database`, `handle_migrations`, `run_seed`, then `start_run`.
- **`prepare_worktree`:**
  - Resolve the ref with `rev-parse --verify --quiet <ref>^{commit}`, otherwise die ``\`<ref>\` does not resolve to a commit in <REPO>.``.
  - Print `step "Worktree  <wt>"` and `mkdir -p` the worktrees, meta and logs directories.
  - **Existing worktree:** compare its HEAD with the tip. If equal, print `ok "already at <9-char sha>"`. If not, print `info "updating <a> -> <b>"`, run `git -C wt checkout --detach --force <tip>`, and print `ok "moved to <b>"`.
  - **New worktree:** `git worktree prune`, a leashed rm of the directory, `info "creating worktree (detached at <sha>)"`, `git worktree add --detach <wt> <tip>`, `ok "created"`.
  - Then write the meta file, and for each entry in `COPY_FILES` either `cp -R REPO/f wt/f` with `ok "<f> copied from the main checkout"`, or `warn "<f> is declared in COPY_FILES but missing from <REPO>"`. This happens **on every run**.
- **`install_deps`:** skipped when `INSTALL` is empty; otherwise it runs **every time**. (Quirk: `example.conf`'s comment claims it is skipped when deps exist.) Output:
  - `step "Dependencies"`, `info "<INSTALL>   (first run on a branch can take a few minutes)"`, `info "logging to <LOG_DIR>/install.log"`, a blank line;
  - the command's output, teed live: `(cd wt && eval "<prelude><INSTALL>" 2>&1) | tee <log>`;
  - a blank line, then `ok "dependencies installed"`.
  - **Failure classification:** a log matching `ERR_PNPM_FETCH_401|401 Unauthorized|npm\.pkg\.github\.com.*(401|Unauthorized)` (case-insensitive) gets the registry-401 die with fix `gh auth refresh -h github.com -s read:packages\n    cd <wt> && <INSTALL>`. A log matching `ERR_PNPM_OUTDATED_LOCKFILE|frozen-lockfile|npm ci.*can only install` gets the lockfile die. Anything else dies `Install failed. ...`.
- **`bring_up_infra`:** only when `COMPOSE_SERVICES` is set.
  - `require_cmd docker`. If `docker info` fails, die with `open -a Docker`.
  - `COMPOSE_PROJECT` defaults to the project id **here only**.
  - Print `step "Infrastructure  (compose project: P)"` and `info "docker compose up -d --wait <svcs>"`, then run `docker compose -p P -f <wt>/<COMPOSE_FILE> up -d --wait <svcs>` with output discarded, then `ok "<svcs> healthy"`.
- **`setup_run_database`:** see 5.7.
- **`handle_migrations` and `run_seed`:** `step "Database"` or `"Seed"`, `info <cmd>`. Migrations also print `dim "this mutates the shared database — every branch of this project uses it"`. The command runs via `(cd wt && eval "<prelude><cmd>")` with output streamed. On success `ok "migrations applied"` or `ok "seeded"`.
- **`start_run`:**
  - Print `step "Servers"`. For each target, `start_server` (5.9), which prints `ok "<t> started (pgid <pid>) -> <log>"`.
  - **Write the state file** (5.3), after every server has started and *before* any health wait.
  - Print `step "Waiting"`. For each target with a port, `wait_for_http "http://localhost:<port><health or />" <t> 240 <pid>`:
    - it prints `info "waiting for <t> at <url>"`;
    - it polls every 2 s with `curl -s -o /dev/null -m 3 -w '%{http_code}'`, where **any code other than 000 is success**, printing `ok "<t> responding (HTTP <code> after <n>s)"`;
    - at 20, 60 and 120 s it prints `dim "still waiting... (<n>s; a first compile is slow)"`;
    - the pid is checked first on each loop, and a dead pid returns 2.
  - **On failure:** print a blank line, `tail -25 <log>`, and a blank line. Run `stop_run quiet`, then die `<t> never answered within the timeout` (or `<t> exited while starting`), with `.` and the log path. The fix is `cd <wt> && <cmd>`. When the run is shifted and the command has no `{port}`, the message gains `on port N.\n\n<shifted note>` and the fix becomes the `--port {port}` suggestion (test-pinned: `does not say where to`, the shifted port number, `{port}`).
  - Print `step "Ready"`, then `info "<t padded to 8> http://localhost:<port>"` per target.
  - `open <first url>` unless `OPENS_ITSELF=1`, `RB_NO_OPEN` is non-empty, or no target has a port.
- **Exit:** 0 once every target answered, 1 on any die. **Servers outlive the engine process** (5.9).
- A success transcript without a TTY (blank lines are shown here; the app drops them):

```
Fixture — feature/one (web)

==> Worktree  /…/.runbranch/fixture/worktrees/feature-one
        creating worktree (detached at 1a2b3c4d5)
    ok   created

==> Servers
    ok   web started (pgid 12345) -> /…/.runbranch/fixture/logs/web.log

==> Waiting
        waiting for web at http://localhost:4321/
    ok   web responding (HTTP 200 after 0s)

==> Ready
        web      http://localhost:4321
```

#### 1.20.1 `ensure_ports_free` (dies before anything starts)

This uses per-port `lsof -t`, and the holder's own run is **not** exempt here, because `do_run` has already stopped it. Each held port becomes one of these lines:

- `  <t> on port <p>  ->  Runbranch is running <owner> here (pid <pid>)` for kind `ours`;
- `  <t> on port <p>  ->  <owner> is running already, started outside Runbranch (pid <pid>)` for kind `outside`;
- `  <t> on port <p>  ->  <ps desc>` when there is no owner.

If any owner is named, die `Ports this project needs are held by another Runbranch run:<lines>\n\nTwo projects that both default to the same port cannot run at once. Stop the\nother run, or give one of them different ports in its config.`. The fix is `<SELF> stop <owner>` for each owner, followed by `# then start this one again` and `<SELF> get <PROJECT> | grep TARGETS      # to change ports instead`.

Otherwise die `Something is already listening on a port this needs:...`.

Tests pin these substrings: `running holder here`, `stop holder`, `started outside Runbranch`. They also require that the output **does not** contain `stop wants`.

### 1.21 `update <project>` (app, streamed)

- Dies `<NAME> is not running.` when nothing is live, and `<NAME> is running in place, so it is already on the working tree.` for an in-place run (test-pinned: `already on the working tree`).
- Otherwise it saves the ref, preset and offset; runs `stop_run` (with output); restores the offset; sets `IN_PLACE=0`; and runs `do_run ref preset`.
- Tests: after a new commit, `behind` goes from 1 to 0 and the run stays on the same ref.

### 1.22 `stop <project>` (app: streamed, and via `failure` when resolving ports)

- With no state file: `        Nothing is recorded as running for <NAME>.` and exit 0.
- Otherwise:
  1. Print `step "Stopping  <NAME> — <S_REF> (<S_PRESET>)"`.
  2. Run `kill_group` for each recorded pid: `kill -TERM -pgid`, falling back to `kill -TERM pid`; poll `kill -0` for up to 12 s; then `kill -KILL -pgid`, falling back to `-KILL pid`.
  3. **`rm` the state file.**
  4. **Reap strays:** for each state target, with the port computed from the *restored* offset, if `lsof -t` finds a holder whose `ps -o command=` contains `<WORKTREES>`, send it `kill -TERM`. Any other holder is listed in `    warn Still listening, and not started by this launcher:\n  port P  ->  <desc>` followed by `dim "Left alone on purpose. Stop it yourself if it is in the way: kill <pid>"`.
  5. Print `ok "stopped"`.
- **Exit:** 0.
- The `quiet` form, used internally, prints nothing.

### 1.23 `remove-worktree <project> <ref>` (app, streamed)

- **Args:** exactly 3.
- No directory: `        No worktree for <ref>.` and exit 0.
- If it is the live run's worktree, die `<ref> is running, so its worktree is in use.`, fix `<SELF> stop <p>`.
- Otherwise:
  1. Print `step "Removing worktree for <ref>"`.
  2. Run `drop_run_database` (5.7).
  3. Run `git worktree remove --force <wt>`, falling back to a leashed rm plus prune.
  4. Remove the meta file and print `ok "removed <wt>"`.

### 1.24 `remove <project>` (app, streamed)

- **Args:** `$# >= 2`.
- No conf: die `No such project: <name>` (test-pinned).
- The project is loaded (it must load). If it is running, die `<name> is running.`, fix `<SELF> stop <name>` (test-pinned: `stop busy`).
- Otherwise:
  1. `rm` the conf. (Quirk: a stray `.bak` is not removed.)
  2. `rm -rf <RB_HOME>/<name>`, but only when the path matches `"$RB_HOME"/?*`.
  3. Drop the name from favourites, via `favourites.tmp` and `mv`.
  4. Print `        Removed <name>. Its repository was not touched.` (test-pinned: `repository was not touched`).

### 1.25 `refresh <project>` (app, via `capture`; output ignored)

`refresh_pr_cache` runs synchronously. It prints `refreshed` to stdout on success, or `refresh failed` to stderr on failure. **It exits 0 either way**, apart from load failures.

### 1.26 `reclaim [<project>]` (app: no arg, once at launch before anything else)

- **Per project (`reclaim_project`):**
  - The state is *stale* when a state file exists but no pid is alive.
  - For each target (effective port; the offset comes from the state if one exists), if `lsof -t` finds a holder whose `ps` command contains `<WORKTREES>` and no run is live: print `        <NAME>: reclaiming <t> on port <p> (pid <pid>)` and `kill_group pid`.
  - When stale: print `        <NAME>: clearing stale state for <S_REF>` and `rm` the state file.
- **With no arg:** every loadable project, then `        Nothing to reclaim.` if nothing happened.
- **Exit:** 0 in both forms. Internally the return status carries a count.

### 1.27 Shell-only human commands

- **`status [<project>]`:**
  - When running: `\n<NAME> running\n  branch    <ref>\n  running   <preset>\n  worktree  <wt>\n  since     <started>\n`, then `  %-9s http://localhost:<port>` for each target, then `  logs      <dir>\n\n`. Exit 0.
  - When not running: `\n<NAME>: nothing running.\n\n` and exit 1.
  - With no arg, it prints every running project and, if there are none, `\nNothing running.\n\n` with exit 1.
  - Tests use it to read `4602` from a shifted run.
- **`doctor [<project>]`:** a `step <NAME>` header, then `info "config    <conf>"`, plus `ok "in-repo   <file> (local file overrides it)"` when one exists. Then `ok` or `warn` lines for:
  - `repo` (`.git` directory);
  - `branch` (`DEFAULT_BRANCH^{commit}` resolves);
  - each `copy` entry exists;
  - the first non-`KEY=` word of `install` is on `PATH`;
  - `docker` and `compose` (when services are set);
  - `runtime` is on `PATH` (`nvm` always passes);
  - each `target`'s head command is on `PATH`, shown as `target    <t> -> <head> on port <declared>`;
  - `github` (gh present and a slug found; otherwise a `dim` line).

  Exit 1 on any warning. With no arg it covers every project (a load failure prints the die and sets rc=1) and then `report_port_overlaps`, which prints the text `claimed by more than one project` with `printf '    %-6s %s\n' port projects` rows and advice (test-pinned: the port, `twinA twinB`, and the text itself, which must be **absent** when there are no overlaps).
- **`cleanup <project>`:** an interactive numbered list of worktrees with their `du -sh` sizes, reading a space-separated list from stdin. With no TTY or no input it removes nothing.
- **`menu`** (no args or an empty first arg): without a TTY it dies `This is the engine, not the front end.`, fix `open '<SELF_DIR>/Runbranch.app'`. With a TTY it runs the project, branch and preset pickers, then `run` (or offers to stop a live run). The branch picker hides non-default branches that are `MERGED` or older than 604800 s.

---

## 2. Who uses what

| subcommand | app | how the app calls it | tests / tools |
|---|---|---|---|
| projects | yes | capture, parsed | engine.sh |
| projects-dir | yes | capture, once | engine.sh |
| branches | yes | capture, parsed | engine.sh |
| presets | yes | capture, parsed | engine.sh |
| paths [ref] | yes | capture, first line | engine.sh |
| state | yes | capture, parsed; called per project for sidebar liveness, every 30 s and after every operation | engine.sh |
| get | yes | capture, parsed (ProjectEditor) | engine.sh |
| set | yes | `Engine.set`: exit code, raw stderr (ProjectEditor, Separate/Move) | engine.sh |
| favourite | yes | failure | engine.sh |
| check-ports | yes | capture: exit code and stdout | engine.sh |
| kill-port | yes | failure | engine.sh |
| ports | yes | capture, parsed, every 30 s | engine.sh |
| overlaps | yes | capture, parsed, every 30 s | engine.sh |
| suggest-offset | yes | capture: exit code and stdout | engine.sh |
| disk | yes | capture, parsed, on demand | — |
| prune-gone | yes | failure | engine.sh |
| scan | yes | capture, parsed | — |
| add | yes | capture: exit code and first line | — |
| refresh | yes | capture, ignored | — |
| reclaim (no arg) | yes | capture, ignored, at launch | — |
| run | yes | **Runner (streamed)** | engine.sh, ui.sh, screenshot.sh |
| update | yes | **Runner** | engine.sh |
| stop | yes | **Runner**; also failure (resolving ports) | engine.sh, ui.sh, screenshot.sh |
| remove-worktree | yes | **Runner** | — |
| remove | yes | **Runner** | engine.sh |
| reclaim <p> | no | — | engine.sh |
| status [p] | no (shell) | — | engine.sh |
| doctor [p] | no (shell; the app's stderr hint names it) | — | engine.sh |
| propose | no (shell; the body of `add`) | — | engine.sh |
| cleanup | no (shell, interactive) | — | — |
| menu, help | no (shell) | — | — |

No subcommand exists only for tests.

---

## 3. Streaming (Runner)

- Only **`run`, `update`, `stop`, `remove-worktree` and `remove`** run under `Runner`.
- **stdout and stderr share one pipe.** Each chunk read (`availableData`) goes through three steps:
  1. It is decoded as UTF-8. **A chunk that fails to decode is dropped entirely.**
  2. ANSI codes are stripped.
  3. It is split on `\n`, and each non-empty piece becomes a displayed line.
- **No prefixes or markers are parsed.** `==>`, `ok`, `warn`, `FAILED` and `Fix:` are purely visual.
- Success or failure comes only from the exit status: `failed = terminationStatus != 0`. On success the sheet closes itself after 0.8 s. On failure it stays open and offers "Copy log".
- **Implications for Go:**
  - Write whole lines per `write()` and flush often. A chunk boundary inside a line shows up as two lines, and one inside a multibyte character (`—`, `→`) drops the whole chunk.
  - Keep stdout and stderr interleaved in order.
- **Cancel** sends `SIGTERM` to the engine pid only (`Process.terminate()`). Servers already started are in their own process groups and survive. The state file is written only once every server has started, so a cancel during install or start can orphan a server with no state. `reclaim` at the next launch catches it, provided its command line contains the worktrees path.
- **Other long-lived output:** the app **tails `<LOG_DIR>/<target>.log`** itself, every 1.5 s, starting at the last 256 KiB. It treats a file that got **shorter** as a restart, because `start_server` truncates the log. Go must keep one log file per target at that path and truncate it at start.

---

## 4. Environment variables

**Read by the engine:**

| var | default | effect |
|---|---|---|
| `RB_HOME` | `$HOME/.runbranch` | root for state, worktrees, logs, the PR cache, meta, favourites, and bundled-mode projects |
| `RB_PROJECTS_DIR` | if the script's directory matches `*/Contents/Resources`, `*/Contents/Resources/*`, `*/Contents/MacOS` or `*/Contents/MacOS/*`, then `$RB_HOME/projects`; otherwise `<script dir>/projects` | where `*.conf` live. Setting it also disables bundle migration |
| `RB_MY_EMAILS` | `git config --get user.email`, run in the engine's cwd (so a repo-local config could leak in) | space-separated; substring match against the author email |
| `RB_PR_TTL` | `900` | PR cache age, in seconds, before a background refresh |
| `RB_NO_OPEN` | unset | any non-empty value suppresses opening the browser after a run |
| `NO_COLOR` | unset | disables colour on a TTY |
| `HOME` | — | the defaults above; `~` expansion; the `scan` default; `propose` writes `REPO` with `$HOME` replaced by `~` |
| `PATH` | — | hardened: appends whichever of `/opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin ~/.local/bin ~/Library/pnpm /Applications/Docker.app/Contents/Resources/bin` exist and are missing, then exports. If `node` is missing and `fnm` exists, `eval "$(fnm env)"` |
| `PORT` | — | **set** (exported) for each server to its effective port |

`RB_OTHER_LIMIT` is documented in `docs/config.md` (default 80) but **no code reads it**.

**Read by the app, not the engine:**

- `RB_ENGINE`: engine path override; must be executable.
- `RB_SCAN_ROOT`: default folder for the Scan sheet.
- `RB_SHOT_LOG`, `RB_SHOT_QUIET`, `RB_SELFTEST_OUT`: screenshot and self-test plumbing.
- `RB_SHOT_ANY_SCALE`: used by `tools/screenshot.sh`.

Every `RB_*` variable set on the app flows through to the engine, because the app's own environment wins over the login shell's.

**Test harness settings:**

- `tests/engine.sh` sets `RB_HOME=$TMP/state`, `RB_PROJECTS_DIR=$TMP/projects`, `RB_MY_EMAILS=tester@example.com` and `RB_NO_OPEN=1`.
- `tests/ui.sh` points `RB_PROJECTS_DIR` and `RB_HOME` at `demo/`, and sets `RB_MY_EMAILS=dana@example.com`.

---

## 5. On-disk layout and formats

```
<PROJECTS_DIR>/<id>.conf            local config (bash). <id> = filename minus .conf
<PROJECTS_DIR>/<id>.conf.bak        transient, during `set`
<REPO>/.runbranch                   optional in-repo config (bash), layered under the local one
<RB_HOME>/favourites                one project id per line, exact-line matched
<RB_HOME>/favourites.$$ | .tmp      transient
<RB_HOME>/projects/                 bundled-mode PROJECTS_DIR
<RB_HOME>/<id>/                     WORK_ROOT
  worktrees/<slug>/                 WORKTREES: throwaway detached git worktrees
  meta/<slug>.ref                   the ref that owns the slug, plus \n
  logs/<target>.log                 per-target server output (stdout+stderr), truncated each start
  logs/install.log                  last INSTALL output
  state                             run state (5.3); present = "recorded", liveness via pids
  prcache                           PR cache TSV (5.6)
  prcache.$$                        transient during a refresh
  branches                          written only by the terminal picker (collect_branch_data output)
```

### 5.1 Bundle migration

This runs on every invocation, but only when `RB_PROJECTS_DIR` is unset **and** `PROJECTS_DIR == $RB_HOME/projects`:

1. `mkdir -p` that directory, so it exists even when empty.
2. Copy each `<SELF_DIR>/projects/*.conf` into it, **never over an existing file**.

Tests check three things: `projects-dir` gives `<home>/projects`; carried files show up in `projects`; a modified copy is not overwritten. A checkout still reports `<repo>/projects`.

### 5.2 Config format and loading

- **The files are bash, sourced into the engine's shell**, so they can run arbitrary code.
- Before sourcing, the local file is checked with `/bin/bash -n <file>`. On failure the engine dies with the syntax-error message (0.6). **The in-repo `.runbranch` is not syntax-checked.**
- **Defaults, reset before each source (`reset_project_defaults`):**

| key | default |
|---|---|
| `PORT_OFFSET` | `0` |
| `IN_PLACE` | `0` (quirk: a conf can set this) |
| `NAME`, `REPO`, `INSTALL`, `COPY_FILES`, `COMPOSE_PROJECT`, `COMPOSE_SERVICES`, `MIGRATE`, `SEED`, `TARGETS`, `ALWAYS`, `PRESETS`, `SYMBOL`, `RUNTIME`, `DB_URL_VARS`, `DB_TEMPLATE`, `DB_ADMIN_USER` | empty |
| `DEFAULT_BRANCH` | `main` |
| `COMPOSE_FILE` | `docker-compose.yml` |
| `OPENS_ITSELF` | `0` |
| `PROCFILE` | `0` |
| `PORT_BASE` | `5000` |
| `PORTS` | `fixed` (unused) |

- **Layering:**
  1. Reset, then source the local file.
  2. Expand `REPO`: a leading `~` becomes `$HOME` plus the rest.
  3. If `$REPO/.runbranch` exists: reset, source the in-repo file, source the local file again, and expand `~` again. `IN_REPO_CONFIG` is set to its path.
- **Validation:**
  - `NAME` falls back to the id.
  - `REPO` is required, and `$REPO/.git` must be a **directory**. (Quirk: a linked worktree or submodule, which has a `.git` file, is rejected.)
  - `PROCFILE=1` with empty `TARGETS` derives targets from `$REPO/Procfile`. Each `name: cmd` line (blank lines, `#` lines and lines without `:` are skipped) becomes `name:<PORT_BASE+i*100>:/:PORT=<that port> <cmd, leading spaces trimmed>`.
  - `TARGETS` is required.
- **Syntax that appears in real and test confs** (a non-bash parser needs at least all of this):
  - `KEY="value"`, `KEY=value`, `KEY=1`.
  - `# comments`, including trailing ones: `KEY="v"   # note`.
  - **Double-quoted values that span lines** (multi-line `TARGETS`).
  - **Backslash escapes inside double quotes**, for example `\"public\"` in `tests/engine.sh`'s envport conf, which becomes a literal `"`.
  - Single quotes nested inside a double-quoted value, which are literal.
  - Potentially `$HOME` or `${VAR}` expansion; the docs imply "plain bash".
- **TARGETS grammar:** one per line, `name:port:healthpath:command`. Lines that are empty or start with `#` are skipped. **Only the first three colons separate**, so the command may contain colons. Names are word-split elsewhere, so they must not contain spaces, and **a line must not be indented** (the leading spaces would become part of the name). If a name is repeated, the first match wins. An empty health path means `/`. A target with an empty port is still *started* but is never health-waited or port-checked. `{port}` in the command is replaced with the effective port.
- **PRESETS:** whitespace-separated `label=t1,t2` entries. **ALWAYS:** space-separated target names. **COPY_FILES:** space-separated relative paths. **DB_URL_VARS:** space-separated variable names.
- **Effective port** = declared port + `PORT_OFFSET`. The offset comes from the conf, from the `run` argument (which replaces it), or from the state file after `load_state`.
- **Writing the file:** only `set` (1.8) and `add`/`propose` write it. The engine never rewrites a conf in any other way.

### 5.3 The state file (`<WORK_ROOT>/state`)

`KEY=VALUE` lines, written in this order:

```
REF=<ref>
WORKTREE=<abs path; REPO for in-place>
PRESET=<preset>
TARGETS=<space-separated target names, in start order>
PIDS=<space-separated pgids, same order>
PORT_OFFSET=<n>
IN_PLACE=0|1
STARTED=YYYY-MM-DD HH:MM:SS
EPOCH=<unix seconds>
```

- Reading splits each line at the **first** `=`. Unknown keys are ignored.
- **"Running"** means the file exists **and** at least one pid passes `kill -0`.
- `PORT_OFFSET` and `IN_PLACE` are restored into globals on every read.
- Tests read the file directly. They check `^IN_PLACE=1$`, `^PORT_OFFSET=1$` and `^WORKTREE=`, and check whether the file exists (it lingers after the processes die, and `reclaim` removes it).

### 5.4 Worktree slugs

1. `slug_for(ref)`: strip a leading `origin/`, then replace every `[^A-Za-z0-9._-]` with `-`.
2. **Collision:** if `meta/<base>.ref` exists and holds a non-empty ref other than this one, the slug becomes `<base>-<digest>`. `digest = printf '%04x' (POSIX cksum CRC of the ref bytes % 65536)`. **This is POSIX `cksum`, not CRC-32/IEEE.** The suffixed slug is not checked for a second collision.
3. The meta file is written (`<ref>\n`) on every `prepare_worktree`.
4. Tests check that `feat/a-b` and `feat/a+b` get 2 directories, the first keeps `feat-a-b`, and both meta refs are recorded.

The "leash" (`safe_rm_worktree`) refuses to delete any path whose physical parent is not `WORKTREES`, or that is `WORKTREES` itself. It dies `Refusing to delete <path> — it is not a throwaway worktree under <WORKTREES>.`

### 5.5 Favourites

Plain text, one id per line. The app's sidebar order is Running, then Favourites, then Projects. `remove` drops the entry.

### 5.6 PR cache (`<WORK_ROOT>/prcache`)

- **Format:** TSV `headRefName\tstate\tnumber\ttitle\tauthorLogin`, from gh's `@tsv`, which escapes tabs in titles. The author column is unused.
- **Refresh:** requires `gh` and a GitHub slug. It runs:

  ```
  gh -R <slug> pr list --state all --limit 300 --json headRefName,state,number,title,author --jq '.[] | [.headRefName, .state, (.number|tostring), .title, .author.login] | @tsv'
  ```

  into a tmp file, which is `mv`'d into place only when non-empty.
- **`ensure_pr_cache`:** with no cache or an empty one, it refreshes **synchronously**. If the file's mtime is older than `RB_PR_TTL`, it starts a **detached background** refresh and returns at once with the stale data. Bash reads the mtime with `stat -f %m` (BSD).

### 5.7 Per-run databases (`DB_URL_VARS`; Postgres only; worktree mode only)

- **Source URL:** for the first variable in `DB_URL_VARS`, take the last `^VAR=` line across `$REPO/<COPY_FILES...>` (the first file that has one wins), remove `VAR=`, and delete every `"` and `'`. If it is missing, die, naming the variable.
- **Name:** `base` = the URL path segment (`sed -E 's#^.*/([^/?]+)(\?.*)?$#\1#'`). The run database is `<base>_rb_<slug>`, with every `[^A-Za-z0-9_]` turned into `_`, cut to 63 bytes.
- **psql:**
  - Container: `docker compose -p <COMPOSE_PROJECT> -f <wt>/<COMPOSE_FILE> ps -q postgres | head -1`. The service name `postgres` is hard-coded.
  - Command: `docker exec <cid> psql -U <DB_ADMIN_USER or the user in the URL> -d postgres -v ON_ERROR_STOP=1 -tAc "<sql>"`.
- **Create:**
  1. `step "Database  <name>"`.
  2. Check with `SELECT 1 FROM pg_database WHERE datname='<name>'`. If it exists, print `ok "already exists — reusing it"`.
  3. Otherwise run `CREATE DATABASE "<name>"` (with `TEMPLATE "<DB_TEMPLATE>"` when set) and print `ok "created"`.
  4. Then **rewrite the worktree's copies of each `COPY_FILES` entry**: every line matching `^VAR=.*` becomes `VAR=<source URL with its path segment replaced by the run database>`, for **every** variable in `DB_URL_VARS`. (Quirk: every variable gets the *first* variable's URL.) Bash does this with `/usr/bin/sed -i '' -E` (BSD).
  5. Print `ok "<COPY_FILES> now points at <name>"`.
- **Drop** (in `remove-worktree`): `DROP DATABASE IF EXISTS "<name>" WITH (FORCE)`, never when `name == base`. (Quirk and bug: inside `drop_run_database`, `psql_admin`'s die is not wrapped, with its output sent to `/dev/null`. If `COMPOSE_PROJECT` is unset in the conf, or docker or postgres is down, `remove-worktree` **exits 1 silently** before removing anything.)
- **`psql_admin`'s die message** when no container is found: `<NAME> declares DB_URL_VARS but has no running postgres service to create the database in.`

### 5.8 Port attribution (`port_holder_owner <pid>`, which yields `project\tkind`)

- `hay = "<ps -o command= -p pid> <cwd from lsof -a -p pid -d cwd -Fn>"`.
- If `hay` contains `"$RB_HOME/"`, the owner is the path segment right after `RB_HOME/` and the kind is `ours`. (Quirk: `RB_HOME/projects/...` would give `projects`.)
- Otherwise, for each loadable project, if `hay` contains that project's `REPO` as a **substring**, the kind is `outside`, first match wins. (Quirk: `/x/app` also matches `/x/app2`.)
- Otherwise the result is `\tunknown`.
- **Consequence:** an **in-place** run started by Runbranch runs in `REPO`, not under `RB_HOME`, so it is attributed as `outside`, and neither `stop`'s stray reaping nor `reclaim` treats it as ours.
- **Listener snapshot:** `lsof -nP -iTCP -sTCP:LISTEN -Fpn`. Records are `p<pid>` followed by `n<addr>`. Addresses containing `->` are skipped. The port is the text after the last `:`, and it must be numeric. This gives `port\tpid` lines, and the first match wins. The single-port form is `lsof -nP -iTCP:<p> -sTCP:LISTEN -t | head -1`.
- **Description:** `ps -o pid=,command= -p <pid>`, leading spaces stripped, cut at 110 characters (70 in `ports`).

### 5.9 Starting servers

- The command is the target's command with `{port}` replaced by the effective port. The log `<LOG_DIR>/<t>.log` is truncated first.
- With `set -m`, which gives the job **its own process group, pgid = pid**, bash runs:

  ```
  ( cd <wt> && export PORT=<port> && exec nohup /bin/bash -c "<runtime prelude><cmd>" ) > log 2>&1 &
  ```

  and then `disown`. The recorded pid is that group leader.
- After a `sleep 1`: if `kill -0 pid` fails, print a blank line, `tail -20 log` and a blank line, then die `<t> exited immediately. Its log is above and at <log>.`, fix `cd <wt> && <cmd>`. A shifted run without `{port}` gets the shifted note and the `--port {port}` fix instead.
- **Runtime prelude**, keyed on `RUNTIME`:

| RUNTIME | prelude |
|---|---|
| `mise` | `eval "$(mise activate bash --shims 2>/dev/null \|\| true)"; ` |
| `fnm` | `eval "$(fnm env 2>/dev/null \|\| true)"; fnm use --install-if-missing >/dev/null 2>&1 \|\| true; ` |
| `asdf` | `. "$(brew --prefix asdf 2>/dev/null)/libexec/asdf.sh" 2>/dev/null \|\| true; ` |
| `nvm` | `. "$HOME/.nvm/nvm.sh" 2>/dev/null && nvm use >/dev/null 2>&1 \|\| true; ` |
| other | none |

  The same prelude wraps `INSTALL`, `MIGRATE` and `SEED`, which run through `eval` in a subshell whose cwd is the worktree.
- **Stopping** signals the whole group (`kill_group`, see 1.22). That is what stops watchers such as `tsx --watch` from respawning. **On Windows a Go engine needs an equivalent that kills the whole tree** (a Job Object, or `taskkill /T`) and a detached child that survives the engine exiting.

---

## 6. External tools

| tool | used for |
|---|---|
| `git -C <REPO> rev-parse --abbrev-ref HEAD` | current branch (isCurrent, in-place check, adopted ref, switched) |
| `git rev-parse --verify --quiet <ref>^{commit}` | resolve a ref to its tip; gone detection; doctor's branch check; behind |
| `git rev-parse --verify --quiet refs/remotes/origin/<def>` or `refs/heads/<def>` | choose the trunk |
| `git -C <wt> rev-parse HEAD` | a worktree's pinned commit |
| `git for-each-ref --sort=-committerdate --format=…%09… refs/heads` and `refs/remotes/origin` | branch rows (`%09` is a literal tab; git does not interpret `\t`) |
| `git for-each-ref --count=1 --format=%(ahead-behind:<trunk>) <trunk>` | probe for the ahead/behind atom (git 2.41 or later) |
| `git worktree list --porcelain` | foreign worktrees |
| `git worktree add --detach <wt> <tip>` / `remove --force` / `prune` | the worktree lifecycle |
| `git -C <wt> checkout --detach --force <tip>` | move an existing worktree |
| `git rev-list --count A..B` | commits behind |
| `git config --get remote.origin.url` | GitHub slug |
| `git config --get user.email` | default `MY_EMAILS` |
| `git -C <dir> symbolic-ref --short refs/remotes/origin/HEAD`, `check-ignore -q <f>` | propose |
| `gh -R <slug> pr list …` | PR cache |
| `docker info` | daemon check |
| `docker compose -p P -f F up -d --wait <svcs>` | infrastructure |
| `docker compose … ps -q postgres` | postgres container id |
| `docker exec <cid> psql …` | create or drop the per-run database |
| `lsof -nP -iTCP -sTCP:LISTEN -Fpn` | snapshot of every listener |
| `lsof -nP -iTCP:<p> -sTCP:LISTEN -t` | single-port holder |
| `lsof -a -p <pid> -d cwd -Fn` | a process's cwd, for attribution |
| `ps -o command= -p` | attribution; stray and reclaim test (contains WORKTREES) |
| `ps -o pid=,command= -p` | human description |
| `ps -o lstart= -p` | adopted start time |
| `ps -p` | existence (kill-port) |
| `kill -0`, `-TERM`, `-KILL`, on the pid or `-pgid` | liveness and stopping |
| `curl -s -o /dev/null -m 3 -w %{http_code}` | health wait (any non-000 code is up) |
| `nohup`, `/bin/bash -c` | detached server launch |
| `/bin/bash -n` | conf syntax check |
| `open <url>` (macOS) | open the browser after a run |
| `python3` | read `package.json` scripts (propose); rewrite conf keys (set) |
| `stat -f %m` (BSD) | PR cache mtime |
| `date +%s`, `date '+%Y-%m-%d %H:%M:%S'`, `date '+%Y-%m-%d'`, `date -j -f` (BSD) | timestamps; parse lstart |
| `/usr/bin/sed -i ''` (BSD) | rewrite database URLs in worktree env files |
| `du -sk` / `du -sh` | worktree sizes (disk / cleanup) |
| `find -maxdepth 3 -type d -name .git` | scan |
| `cksum` | slug collision digest |
| `cp -R`, `mv`, `rm -rf`, `mkdir -p`, `touch`, `tee`, `tail -20` / `-25`, `awk`, `sed`, `grep`, `sort`, `tr`, `cut`, `head`, `wc`, `seq` | plumbing |
| `mise`, `fnm`, `brew --prefix asdf`, `~/.nvm/nvm.sh` | runtime activation inside the worktree |
| user commands (`INSTALL`, `MIGRATE`, `SEED`, target commands) | run through `eval` / `bash -c`, so they are **shell strings**. A Go engine still needs a shell to run them (bash, or cmd/pwsh on Windows, which changes semantics) |

The engine **never** fetches, checks out, stashes or otherwise writes to the user's checkout. It only reads refs, copies `COPY_FILES` out of it, and runs git-worktree metadata operations. Tests verify the checkout stays on `main` and that untracked files survive an in-place run.

---

## 7. Quirks and bugs to decide on before porting

1. **`set` swallows lines after an assignment that ends in a trailing comment.** This is data loss, and it applies to configs written by `propose` (1.8).
2. **`get` omits `PORT_OFFSET`**, so the editor's offset field always loads empty (1.7).
3. **A live or stale state file overrides the requested `PORT_OFFSET` and `IN_PLACE`** during `run` (1.20, step 4).
4. **An unknown preset never errors**; it becomes a one-target preset with that name (1.4).
5. **`check-ports`' `OFFSET` is relative to the declared port** while its lines show effective ports. `Ports.swift` adds the two (1.10).
6. **`remove-worktree` exits 1 silently** for a per-run-database project when docker, postgres or `COMPOSE_PROJECT` is missing (5.7).
7. **Every `DB_URL_VARS` variable is rewritten to the first variable's URL** (5.7).
8. **In-place runs are attributed `outside`** (5.8).
9. **`ready` is never 1 for remote rows** (1.3).
10. **Substring matching** is used for emails, repo paths and `RB_HOME` (1.3, 5.8).
11. **`RB_OTHER_LIMIT` is documented but not implemented.** `example.conf` claims `INSTALL` is skipped when deps exist, which is false.
12. **`tests/engine.sh:464` expects `"\t1"`** for overridable, but the field is now `explicit` or `env`.
13. **BSD-only calls** (`stat -f`, `date -j`, `sed -i ''`, `open`) and **POSIX-only process handling** (pgid signals, `lsof`, `ps`) all need Windows equivalents.
14. **Config files are bash.** A Go engine has to embed bash, shell out to it, or implement a restricted parser that covers the syntax in 5.2. This is the biggest compatibility decision in the port.

---

## 8. Added by the Go engine: long paths and `install-update` (spec F17)

Not in `runbranch.sh`. Nothing here changes a byte of any output above.

### 8.1 Long paths, without an administrator

- **Every git the engine runs gets `-c core.longpaths=true`**, on every OS, from one place (`gitx.Command`). Git ignores the key off Windows, so the Mac runs exactly the arguments Windows does. It is never written to anyone's git config.
- **Deletes and copies that walk a tree go through `\\?\` paths** on Windows (`pathx.RemoveAll`, `pathx.Extended`): worktree removal, `node_modules`, `COPY_FILES`, `disk` sizes. Nothing that prints or compares a path uses that form.
- **`doctor` no longer warns** about `LongPathsEnabled` or `core.longpaths`. When `LongPathsEnabled` is 0 it prints one `dim` line (`longpaths Windows long paths are off; Runbranch handles long paths itself, so turning on LongPathsEnabled is optional`) and the exit code is unaffected.
- **A failed `INSTALL`, `MIGRATE`, `SEED` or server** whose output (the last 64 KB) carries a path-too-long signature — `Filename too long`, `path too long`, `ENAMETOOLONG`, `The filename or extension is too long`, `MAX_PATH`, `error 206`, `ERROR_FILENAME_EXCED_RANGE`, `PathTooLongException` — adds a paragraph to the end of its `FAILED` message saying that may be why, and naming the `LongPathsEnabled` switch as the optional fix. Windows only, and only while the switch is off. The `Fix:` block is unchanged.

### 8.2 `install-update <pid> <new-folder> <install-folder> [--staging <dir>] [--work <dir>] [--log <file>] [--no-relaunch]` (Windows app only; internal)

Swaps a downloaded Runbranch in for the running one and starts it again: the Windows counterpart of `tools/install-update.sh`, which the Mac keeps. Listed in the usage text under "internal, run by the Windows app only". It runs before PATH hardening and bundle migration, and never prints `FAILED`.

- **Who runs it:** `Updates.cs`, hidden (`CreateNoWindow`), immediately before the app quits, from a **copy** of the engine in the download folder — the installed `bin\runbranch.exe`, or the new one's if that is missing. Never the one in place: it is inside the folder being replaced.
- **Arguments:** `<pid>` is the app. `<new-folder>` is the extracted update (it must hold `Runbranch.exe` and `bin\runbranch.exe`). `<install-folder>` is the folder being replaced. `--staging` is the folder the update was extracted into and `--work` the download folder, both removed at the end; `--log` defaults to `%LOCALAPPDATA%\Runbranch\update.log`, truncated per attempt; `--no-relaunch` is for tests.
- **Order:**
  1. Refuses, logging `FAILED: … ; nothing changed` and exiting **1 before step 2**, when the new folder lacks either exe, the install folder is not a folder, or the two overlap. The app, still open, reports `The installer stopped before it began`.
  2. Creates `<work>\started`. The app quits only once this exists (it gives up after 10 s).
  3. Waits up to 10 s for `<pid>` to exit, then ends it.
  4. Renames the install folder to `<install>.replaced-<helper pid>` (retried 40 × 250 ms), moves the new folder in (8 tries), and checks `Runbranch.exe` arrived. Any failure puts the old folder back.
  5. Removes the old copy, the staging folder and everything in the work folder except its own exe, which cannot be deleted while it runs; the app sweeps `%TEMP%\runbranch-update-*` folders older than ten minutes at its next launch. A staging or work folder that contains the install folder is never removed.
  6. Starts `<install>\Runbranch.exe` from that folder, detached (its own process group, out of the helper's job when allowed). It does this after a failure too, so the old version comes back.
- **Exit:** 0 swapped; 1 not (the log says why); **2** for a usage error, or on macOS, where it prints `install-update is not used on macOS; the app updates with tools/install-update.sh.` to stderr.
- **stdout:** the log lines, `HH:MM:SS <text>`, for anyone running it by hand. Nothing parses them.
