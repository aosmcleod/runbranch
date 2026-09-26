# runbranch.sh — behaviour inventory for the Go port

Source: `runbranch.sh` (2675 lines, 104 functions, bash 3.2) and `docs/config.md` (217 lines), read in full at v1.5.1 (`91e1cea`).
Line numbers refer to `runbranch.sh` unless noted as `config.md:N`.

---

## 0. Blockers to decide first (not in the brief; read before the rest)

These are architectural, not porting details. They decide how the Go engine is shaped.

| # | Problem | Where | Why it blocks |
|---|---|---|---|
| B1 | **Config files are bash that gets sourced.** `load_project` runs `/bin/bash -n` on the file, then `.`-sources it, twice when there is an in-repo `.runbranch`. | 245-282, config.md:6, 161-166 | With no bash on Windows, Go cannot "source" a conf. Options: (a) parse a strict subset (`KEY="value"` or `KEY='value'`, multi-line double-quoted values, `#` comments, and nothing else), or (b) require bash. Existing confs may use shell features such as `$HOME`, command substitution or conditionals. Audit `projects/*.conf` and real `.runbranch` files before choosing. `set_project_key` (1940) already assumes the `KEY="value"` subset. |
| B2 | **TARGET/INSTALL/MIGRATE/SEED commands are bash command lines.** They run via `/bin/bash -c "$(runtime_prelude)$cmd"` (1459) or `eval` in a subshell (775, 787). Procfile targets get a `PORT=n cmd` prefix, which is bash env-assignment syntax (319). | 761-787, 1459, 319 | cmd.exe and pwsh do not understand `PORT=5000 cmd`, `&&` (Windows PowerShell 5.1), `$VAR`, or `eval "$(fnm env)"`. Decide the Windows shell (`cmd /c`, `pwsh -Command`, or Git Bash when present) and whether confs carry per-OS commands. |
| B3 | **`ref_digest` uses POSIX `cksum` CRC.** | 444 | Existing worktree directory names with a digest suffix (`<slug>-xxxx`) depend on it. Go must implement the POSIX cksum CRC-32 (poly 0x04C11DB7, non-reflected, length appended, final complement) and then `% 65536`, formatted `%04x`. `hash/crc32` is the wrong variant. |
| B4 | **The Swift app parses the engine's stdout.** Every machine-readable subcommand is a wire contract (§1.14). | 2375-2672 | Field order, tabs, `\001` in TARGETS, exit codes and the "add a new line type rather than a new field" rule (2487-2489) must survive byte for byte, or the app has to change in step. |
| B5 | **Process identity comes from the command line plus the cwd** (`ps -o command=`, `lsof -d cwd`). | 1020-1050, 1640, 2107 | Windows has no cheap cwd lookup for a foreign process. Reading the PEB needs `NtQueryInformationProcess` and `ReadProcessMemory`, which fail for elevated or protected processes. Job Objects make "ours" easy to know. "Outside" attribution (the same project, started by someone else) is the hard part. |

---

## 1. Module breakdown (all 104 functions)

Legend for the dependency column: **mac** = macOS-only, **unix** = POSIX/BSD, **ext** = an external binary (git, docker, gh, curl, python3, lsof), **—** = pure logic.

### 1.1 Bootstrap, paths, output (11)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `default_projects_dir` | 58 | `RB_HOME/projects` when the script sits inside `*/Contents/Resources` or `*/Contents/MacOS`; otherwise `SELF_DIR/projects`. `RB_PROJECTS_DIR` overrides (65). | **mac** (.app bundle path shape). Windows needs its own rule, for example "installed under Program Files or LocalAppData\Programs, so use RB_HOME". |
| `migrate_bundle_projects` | 76 | Once per invocation, when PROJECTS_DIR is `RB_HOME/projects` and not overridden: `mkdir -p`, then copies `SELF_DIR/projects/*.conf` into it without overwriting. | unix `cp` / `mkdir -p` |
| `step` / `ok` / `info` / `dim` / `warn` | 116-120 | Formatted output: `==>` heading, `ok`, 8-space indent, dim, `warn`. ANSI colours only when stdout is a TTY and `NO_COLOR` is unset (107-114). | ANSI escapes. Windows Terminal handles them; legacy conhost needs `ENABLE_VIRTUAL_TERMINAL_PROCESSING`. |
| `die` | 124 | Prints ` FAILED <msg>` plus an optional `Fix:` block to stderr, then `exit 1`. | — |
| `ask` | 133 | Y/n prompt. Without a TTY it takes the default and prints `-> yes`, or `-> no (assuming the cautious answer)`. | TTY detection (`-t 1`) |
| `harden_path` | 166 | Appends /opt/homebrew/{bin,sbin}, /usr/local/bin, ~/.local/bin, ~/Library/pnpm and Docker.app's bin to PATH. If node is missing and fnm is present, evaluates `fnm env`. | **mac** paths; `eval` |
| `require_cmd` | 180 | `command -v` or die, naming the searched dirs. | unix `command -v`, so Go uses `exec.LookPath` (PATHEXT on Windows) |
| `usage` | 2375 | Help text; lists every subcommand. | — |
| `need_project` | 2420 | Missing arg means `usage` and exit 2; otherwise `load_project`. | — |
| `main` | 2425 | Runs `harden_path` and `migrate_bundle_projects`, then dispatches (§1.14). | — |

### 1.2 Config parsing and writing (13)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `is_favourite` | 205 | `grep -qxF name RB_HOME/favourites`. | unix grep |
| `set_favourite` | 210 | Rewrites favourites without the name (plus the name when `on`), through `favourites.$$` and `mv`. | unix; atomic rename (Go: `os.Rename`; replacing an existing file on Windows needs MoveFileEx semantics, which `os.Rename` provides) |
| `expand_repo` | 221 | A leading `~` becomes `$HOME`. | — |
| `reset_project_defaults` | 225 | Defaults: PORT_OFFSET=0, IN_PLACE=0, DEFAULT_BRANCH=main, COMPOSE_FILE=docker-compose.yml, PORT_BASE=5000, PORTS=fixed, OPENS_ITSELF=0, PROCFILE=0; everything else empty. | — |
| `load_project` | 235 | Checks `name.conf` exists → `bash -n` syntax check (dies with the parser message and `open -t file`) → reset → source → expand `~` → if `$REPO/.runbranch` exists: reset, source in-repo, source local again, expand `~` again → validates REPO set, `REPO/.git` a **directory** (287; a repo that is itself a linked worktree has a `.git` *file* and is rejected) → derives TARGETS from the Procfile when `PROCFILE=1` and TARGETS is empty → requires TARGETS → sets WORK_ROOT, WORKTREES, LOG_DIR, STATE_FILE, PR_CACHE, META_DIR under `RB_HOME/<name>`. | **`/bin/bash -n`, `.` source (B1)**; `open -t` in the fix text |
| `procfile_targets` | 308 | Each `name: cmd` line becomes `name:<PORT_BASE+i*100>:/:PORT=<port> <cmd>`. Skips blank lines, `#` lines and lines with no colon; trims leading spaces. | bash env-prefix syntax in the output (B2) |
| `list_projects` | 325 | For each `*.conf`, loads it in a subshell and prints `name⇥NAME⇥REPO⇥stateFileExists(0/1)⇥SYMBOL(default shippingbox)⇥favourite(0/1)`. Configs that fail to load are skipped silently. "Running" is state-file existence, **not** liveness. | subshell isolation (Go: a fresh struct per project) |
| `target_field` | 368 | From TARGETS, the `port`, `health` or `command` of the first line whose name matches. Splits on the first three colons only; skips `#` lines and blank lines. Returns 1 when the name is not found. | — |
| `target_names` | 387 | Names of the non-comment TARGETS lines. | — |
| `target_port` | 357 | Declared port + PORT_OFFSET (the effective port). | — |
| `preset_names` | 400 | From PRESETS (space-separated `label=a,b`); otherwise each target name, plus `all` when there is more than one. | — |
| `preset_targets` | 412 | Expands a preset. An unknown preset with no PRESETS falls back to the literal name, so any string is accepted as a single target name. It is **not validated** against TARGETS, which means `run p bogus` starts a target with an empty command. `all` means every target. ALWAYS targets missing from the list are prepended; whitespace is normalised. | `tr`, `sed` (logic only) |
| `set_project_key` | 1940 | Key must match glob `[A-Z][A-Z_]*`. Only the first two characters are checked, because `*` is a glob. Writes `file.bak`, runs a python3 rewriter (replaces `KEY=` lines, skips continuation lines of multi-line quoted values, or appends when absent; `\001` in the value becomes a newline), then re-runs `load_project` in a subshell. If python or the reload fails, it restores `.bak` and dies; otherwise deletes `.bak`. The value is written as `KEY="value"` **with no escaping** of `"`, `$` or backticks. | **python3**; bash re-parse |

### 1.3 Git, branches and PR metadata (11)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `repo_git` | 438 | `git -C "$REPO" …` | ext git |
| `current_branch` | 440 | `rev-parse --abbrev-ref HEAD` (prints `HEAD` when detached). | git |
| `slug_for` | 441 | Strips a leading `origin/`; every char outside `[A-Za-z0-9._-]` becomes `-`. | sed |
| `ref_digest` | 444 | `cksum` CRC of the ref `% 65536`, formatted `%04x`. | **unix cksum (B3)** |
| `gh_repo` | 474 | `remote.origin.url` → `owner/repo` (strips through `github.com[:/]` and a trailing `.git`); empty when the URL is not GitHub. | git, sed |
| `refresh_pr_cache` | 479 | `gh -R slug pr list --state all --limit 300 --json headRefName,state,number,title,author --jq … @tsv` into `prcache.$$`, then `mv` to `prcache` when it is non-empty. Returns 1 when gh or a GitHub remote is missing. | ext gh; `$$` temp file |
| `ensure_pr_cache` | 503 | No cache: refresh synchronously. Cache older than `RB_PR_TTL` (default 900s): refresh in a **detached background subshell** and return immediately. | **`stat -f %m` (BSD)**, `date +%s`, `( … & )` |
| `foreign_worktrees` | 532 | Parses `git worktree list --porcelain` and emits ` ref|path ref|path `, leaving out the main checkout (path == REPO) and paths under WORKTREES. | awk; **path equality is a string compare**, so on Windows git prints `C:/…` with forward slashes while REPO may have backslashes (normalise both) |
| `trunk_ref` | 554 | `refs/remotes/origin/$DEFAULT_BRANCH` when it exists, else `refs/heads/$DEFAULT_BRANCH`, else empty. | git |
| `ahead_behind_atom` | 573 | Probes `for-each-ref --count=1 --format=%(ahead-behind:trunk) trunk`. On success returns the format fragment `%09%(ahead-behind:trunk)`; on failure (git older than 2.41) nothing. | git ≥2.41 feature probe |
| `collect_branch_data` | 581 | Builds the branch table (§1.14 `branches`). Merges PR cache rows (`P`), local heads (`B`) and origin remotes (`R`, skipping `origin`, `origin/HEAD`, and any remote whose short name has a local twin). Sorted by committer date descending, locals first. Computes age buckets (m/h/d/mo; a month is 30 days), mine (substring match of any MY_EMAILS entry in the author email), owner (`me` or the author's first name), PR state (default `NONE`), ready (a worktree dir named `slug(ref)` exists), isDefault, isCurrent, PR number, subject (PR title preferred over the commit subject), isRemote, the foreign worktree path, ahead and behind. | git, awk, `date +%s` |
| `commits_behind` | 2238 | For a running worktree run: `rev-list --count pinned..tip`. Prints 0 for in-place runs, no worktree, an unresolvable ref, or any error. | git |
| `switched_branch` | 2259 | For an in-place run: the current branch when it differs from S_REF; otherwise nothing. | git |

Notes on `collect_branch_data`:
- The awk `slug()` does **not** strip `origin/`, but `slug_for` does. Remote rows therefore look for `origin-foo` while the worktree dir is `foo`, so `ready` is always 0 for remote refs, and for any digest-suffixed slug. Likely a bug. Decide whether the port fixes it or keeps it.
- MY_EMAILS empty (no git user.email) means nothing is "mine".
- The filters for the app (merged, older than a week, remote without a PR, only mine) are applied **in the app**, not here (config.md:93-100). Only the terminal picker filters (§5).

### 1.4 Worktree lifecycle (5)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `worktree_slug` | 457 | `slug_for(ref)`. When `META_DIR/<slug>.ref` exists and names a *different* ref, returns `<slug>-<digest>`. | file read |
| `worktree_path` | 470 | `WORKTREES/<worktree_slug>` | — |
| `prepare_worktree` | 674 | Resolves `ref^{commit}` (dies with a fix of `git fetch origin`) → `mkdir -p` WORKTREES, META and LOGS → when `wt/.git` exists (dir or file): same commit prints ok, otherwise `git -C wt checkout --detach --force tip`. Else `worktree prune` → `safe_rm_worktree wt` → `worktree add --detach wt tip`. Then writes `META/<slug>.ref`, runs `cp -R REPO/f wt/f` for **every** COPY_FILES entry (warns on missing ones), and sets the global `WORKTREE`. | git; **`cp -R`**, which nests when the target is an existing directory (`wt/dir/dir`): a latent bug for directory entries |
| `safe_rm_worktree` | 724 | Refuses (die) unless the path's physical parent equals WORKTREES and the path is not WORKTREES itself; then `rm -rf`. Returns 1 for an empty path, 0 when the path is missing. | `cd … && pwd` resolution (logical pwd; a symlinked RB_HOME could fail the compare); `rm -rf`, which on Windows must cope with read-only files and long paths (`node_modules`) |
| `remove_worktree_for` | 736 | No dir: info and return. Refuses when this worktree is the live run. Otherwise drops the per-run DB, then `worktree remove --force`, with `safe_rm` plus `worktree prune` as the fallback, then deletes the meta file. | git |

### 1.5 Install, copy files, runtime prelude (5 + constant)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `runtime_prelude` | 761 | Shell snippet prepended to every worktree command. mise: `eval "$(mise activate bash --shims)"`. fnm: `eval "$(fnm env)"; fnm use --install-if-missing`. asdf: `. "$(brew --prefix asdf)/libexec/asdf.sh"`. nvm: `. ~/.nvm/nvm.sh && nvm use`. All errors are swallowed. | **bash-only**; asdf assumes Homebrew. Windows: mise (`mise env -s pwsh`, or prepend the shims dir `%LOCALAPPDATA%\mise\shims`), fnm (`fnm env --shell power-shell` / `--shell cmd`, `fnm use --install-if-missing`). asdf has no Windows build. nvm-windows is a different tool with a global `nvm use` and no `.nvmrc` support, so either do not support it or warn. Better in Go: resolve the env once (run `mise env --json` / `fnm env --json`) and inject it into `exec.Cmd.Env`, not a shell prelude. |
| `in_worktree` | 773 | `( cd wt && eval "prelude+cmd" )`, used by MIGRATE and SEED. | eval in the *current* bash, not `/bin/bash -c` |
| `install_deps` | 780 | Runs INSTALL in the worktree through the prelude, tees to `LOG_DIR/install.log`, and checks `PIPESTATUS[0]`. On failure it pattern-matches the log: `ERR_PNPM_FETCH_401 \| 401 Unauthorized \| npm.pkg.github.com.*(401\|Unauthorized)` gives the fix `gh auth refresh -h github.com -s read:packages`; `ERR_PNPM_OUTDATED_LOCKFILE \| frozen-lockfile \| npm ci.*can only install` gives a lockfile-drift message (fix `<pm> install`); anything else prints the log path. | `tee`, `PIPESTATUS`; Go uses `io.MultiWriter(stdout, logfile)` |
| `GH_PACKAGES_REFRESH` | 778 | Constant fix string. | — |
| `cmd_head` | 2022 | First word of a command that is not a `VAR=` assignment (used by doctor). | awk |

### 1.6 Compose, infra and per-branch DB (10)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `compose` | 812 | `docker compose -p $COMPOSE_PROJECT -f wt/$COMPOSE_FILE …` | ext docker |
| `bring_up_infra` | 817 | Skipped when COMPOSE_SERVICES is empty. Requires docker and a responsive `docker info` (fix `open -a Docker`). Defaults COMPOSE_PROJECT to PROJECT **only here**, then runs `up -d --wait <services>` with output hidden. | docker; **`open -a Docker`** (Windows: start `Docker Desktop.exe`) |
| `handle_migrations` | 834 | MIGRATE through `in_worktree`. Prints "this mutates the shared database", which is stale when a per-run DB is active. | shell |
| `run_seed` | 845 | SEED through `in_worktree`. | shell |
| `pg_container` | 856 | `compose wt ps -q postgres \| head -1`. The service name `postgres` is **hardcoded**. | docker |
| `db_name_from_url` | 872 | Last path segment of the URL, with the query stripped. | sed -E |
| `db_source_url` | 875 | First COPY_FILES entry in REPO that exists → last `VAR=` line with its quotes stripped. The pipeline's status is that of `tr`, so it returns 0 even when VAR is absent (empty output). The caller checks for empty. | grep, sed, tr |
| `db_name_for` | 885 | `<base>_rb_<slug>`, non-`[A-Za-z0-9_]` characters become `_`, truncated to 63 **bytes** (`cut -c`). | tr, cut |
| `psql_admin` | 890 | `docker exec <cid> psql -U <user> -d postgres -v ON_ERROR_STOP=1 -tAc sql`. The user is DB_ADMIN_USER, or parsed from the URL (`scheme://user:`, so a password is required for the parse). Dies when there is no postgres container. | docker |
| `setup_run_database` | 903 | Skipped without DB_URL_VARS. Base URL from the first var → run name → `SELECT 1 FROM pg_database` → reuse, or `CREATE DATABASE "x" [TEMPLATE "t"]` → for each var and each COPY_FILES file in the worktree, rewrites the `^VAR=.*` line to the base URL with its path swapped for the run DB. | **`/usr/bin/sed -i '' -E` (BSD in-place)**; `#` is the sed delimiter, so a `#` in a password or URL breaks it; `&` and `\` in the URL also break the replacement |
| `drop_run_database` | 951 | Recomputes the name and returns without action when it equals the base. Runs `DROP DATABASE IF EXISTS "x" WITH (FORCE)` (needs Postgres 13 or later) and ignores failure. | docker. When COMPOSE_PROJECT is unset in the conf, `bring_up_infra`'s default is not applied on this path (remove-worktree), so `docker compose -p ""` fails and the drop is silently skipped: a latent bug. |

### 1.7 Server start, stop, health and state (11)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `shifted_port_note` | 1417 | When PORT_OFFSET≠0 and the command lacks `{port}`: explains that PORT was probably ignored. Returns 1 otherwise. | — |
| `shifted_port_fix` | 1426 | Fix text: an example TARGETS line with ` --port {port}` appended. | — |
| `start_server` | 1437 | Replaces `{port}` with the effective port; truncates `LOG_DIR/<name>.log`; `set -m` (new pgid); `( cd wt && export PORT=… && exec nohup /bin/bash -c "prelude+cmd" ) >log 2>&1 &`; `disown`; `sleep 1`; `kill -0 pid`, or tail -20 of the log and die (with the shifted-port note where it applies). Records STARTED_PID (= pgid). | **`set -m`, `nohup`, `disown`, `/bin/bash -c`, `kill -0`, `tail`** |
| `wait_for_http` | 1482 | Polls `curl -s -m 3 -w %{http_code}` every 2s up to the timeout. Any code other than `000` counts as success. Returns 2 when the pid died, 1 on timeout. Prints "still waiting" at 20, 60 and 120s. | ext curl (Go: `net/http` with a 3s timeout; no redirect following, since curl without `-L` counts a 3xx as up) |
| `write_state` | 1503 | Writes `REF=`, `WORKTREE=`, `PRESET=`, `TARGETS=`, `PIDS=`, `PORT_OFFSET=`, `IN_PLACE=`, `STARTED=YYYY-MM-DD HH:MM:SS` (local time) and `EPOCH=` to `STATE_FILE`. Not atomic. | `date` |
| `load_state` | 1518 | Parses the state file into `S_*`. Also sets the globals PORT_OFFSET and IN_PLACE, but does **not** reset them when the file is absent. Returns 1 when there is no file. | — |
| `alive` | 1543 | `kill -0 pid`, which is false on EPERM. | **unix signal 0** |
| `demo_running` | 1545 | load_state, and any PID in S_PIDS alive. | — |
| `start_run` | 1552 | Starts every target (sequentially, 1s sleep each) → writes state → **for each target in order** runs `wait_for_http http://localhost:<port><health or />` with a 240s timeout → on the first failure prints tail -25 of its log, runs `stop_run quiet`, then dies (with the shifted-port hint) → prints Ready URLs → `open <first URL>` unless OPENS_ITSELF=1 or RB_NO_OPEN is set. | **`open`** |
| `kill_group` | 1610 | No-op when the pgid leader is dead (`kill -0`). `kill -TERM -pgid` (falls back to the pid), then polls `kill -0 pgid` (**the leader only**) for 12×1s, then `kill -KILL -pgid`. If the leader exits but children remain in the group, it returns early and never sends KILL. | **process groups, negative-pid signalling** |
| `stop_run` | 1622 | No state: "nothing recorded", return 0. Otherwise `kill_group` on every PID → **rm state** → for each target port still held, TERMs the holder when its command line contains WORKTREES; otherwise lists it as "left alone on purpose". In-place strays are never reaped, because their command lines do not contain WORKTREES. | lsof, ps, kill |

### 1.8 Run orchestration and status (2)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `do_run` | 1654 | Unknown preset: die. Prints the header → harden_path → require git (fix `xcode-select --install`) → if running: `ask` "Stop it and start this one?" (yes by default without a TTY) → stop_run → `ensure_ports_free` → **in place**: the ref must equal current_branch, WORKTREE=REPO, start_run only. **Worktree**: prepare → install → infra → per-run DB → migrate → seed → start_run. | `xcode-select` fix text is mac |
| `print_status` | 1705 | Human status of the running project (branch, preset, worktree, since, URLs, logs). Returns 1 when idle. | — |

### 1.9 Ports, overlaps, offsets and holder attribution (15)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `port_holder` | 969 | `lsof -nP -iTCP:<port> -sTCP:LISTEN -t \| head -1`. One spawn per call; used by ensure_ports_free, stop_run and reclaim. | **lsof** |
| `listeners_now` | 982 | `lsof -nP -iTCP -sTCP:LISTEN -Fpn`, printed as `port⇥pid`. Skips names containing `->`. The port is whatever follows the last `:` (IPv4, `*`, `[::1]`). | **lsof** (Windows: `GetExtendedTcpTable` with `TCP_TABLE_OWNER_PID_LISTENER` for AF_INET and AF_INET6; macOS in Go: keep lsof, or use `proc_pidinfo`/sysctl `net.inet.tcp.pcblist_n`, which is harder; shelling out to lsof is the pragmatic choice) |
| `holder_in` | 1000 | Looks up a port's pid in a snapshot (first match). | — |
| `port_holder_desc` | 1003 | `ps -o pid=,command= -p pid`, trimmed, cut to 110 chars. | **ps** (Windows: `QueryFullProcessImageName` plus the command line via WMI `Win32_Process.CommandLine` or the PEB) |
| `port_holder_owner` | 1020 | `project⇥ours\|outside\|unknown`. hay = the command line + the cwd (`lsof -a -p pid -d cwd -Fn`). If hay contains `RB_HOME/` then project = the first path segment after it, and the kind is `ours`. Otherwise, for each project (full list_projects + load, O(n) per pid): if hay contains REPO as a **substring**, the kind is `outside`. A `/a/foo` repo also matches `/a/foobar`. Otherwise `⇥unknown`. | **ps, lsof cwd (B5)**; case-sensitive substring (Windows paths are case-insensitive, with mixed separators) |
| `port_holder_project` | 1053 | The project part only. **Unused** (dead code). | — |
| `declared_ports` | 1070 | For every project: `effectivePort⇥project` for each target. | — |
| `port_overlaps` | 1090 | `declared_ports \| sort -u`, counts per port, emits `port⇥proj proj…` where count > 1, sorted numerically. | sort, awk |
| `suggest_offset` | 1108 | The smallest `try` in 0..200 for which every **declared** port + try is neither an effective port of another project nor currently listened on. Prints the number. When nothing is free it prints 0 and returns 1. | lsof via listeners_now |
| `report_port_overlaps` | 1135 | Prose warning plus fix text for doctor. | — |
| `kill_port_holder` | 1173 | Validates the pid is numeric; checks `ps -p` exists (gone means info, return 0); attribution; refuses unless owned by a known project (kind ≠ unknown); `kill -TERM` only; polls `alive` 10×1s; dies with `kill -9 pid` as the fix. The poll uses `alive` (kill -0), which the comment at 1178 warns about: a root-owned process reads as "stopped" at once. | ps, kill |
| `report_ports` | 1212 | For each project and target: `project⇥target⇥port⇥free\|ours\|outside⇥owner⇥kind⇥pid⇥desc(70)`. One listener snapshot. `ours` only when kind=ours **and** owner is this project. | lsof, ps |
| `emit_adopted_state` | 1258 | When no run of ours exists but this project's ports are held with kind=`outside` for **this** project: emits `run⇥<current_branch>⇥⇥<ps lstart>⇥<epoch>⇥<REPO>⇥1⇥1` (in_place=1, adopted=1) plus `target⇥t⇥port⇥health⇥pid⇥1` rows. | **`ps -o lstart=`, `date -j -f '%a %b %d %T %Y'` (BSD)**; the STARTED format differs from write_state's |
| `check_ports` | 1291 | For a preset: emits `target⇥port⇥owner⇥kind⇥pid⇥explicit\|env` for each held port, skipping this project's own `ours` run. When any are found: the smallest `try` in 1..200 where every declared port+try is not listened on (**does not consider other projects' declared ports**, unlike suggest_offset), then `OFFSET⇥try` and return 1. When nothing is free it prints `OFFSET⇥201`, a bug. The comment at 1154-1162 describes `overridable` as 1/0; the code emits `explicit`/`env`. | lsof |
| `ensure_ports_free` | 1346 | Per port (a separate lsof each): collects busy lines with attribution. If any owner is known, dies with "held by another Runbranch run" and a `stop <owner>` fix per owner. Otherwise dies with "something is already listening". It does **not** skip this project's own run, which relies on do_run having stopped it first; an `outside` run of the same project dies here. | lsof, ps |

### 1.10 Disk, cleanup and reclaim (6)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `safe_rm_worktree` | 724 | (see 1.4) | |
| `prune_gone_worktrees` | 2275 | For each worktree dir other than the running one, with a meta ref that no longer resolves: `worktree remove --force` or safe_rm, then delete the meta file. Dirs with no meta file are skipped. Runs `worktree prune` last and emits `pruned⇥N`. Does **not** drop the per-run DB (unlike remove_worktree_for), so it leaks databases. | git |
| `report_disk` | 2309 | `project⇥slug⇥ref(or ?)⇥kbytes⇥running\|gone\|idle` for each worktree. | **`du -sk`** (Go: `filepath.WalkDir` summing sizes. `du` counts allocated blocks and follows no symlinks; on Windows use `GetCompressedFileSize` or just the logical size. Hardlinks from the pnpm store make `du` and a naive walk disagree; `du` counts each inode once.) |
| `cleanup_worktrees` | 2338 | Interactive (§5). | `du -sh` |
| `reclaim_project` | 2095 | stale = a state file exists but no pid is alive. For each target port held by a process whose **command line** contains WORKTREES (no cwd check), and when stale or not running: `kill_group pid` (the pid is used as the pgid, which is only correct if it is a group leader). Clears the stale state file. Returns the count as the exit status (capped at 255). | lsof, ps, kill |
| `reclaim_all` | 2130 | reclaim_project for every project, summing exit codes; prints "Nothing to reclaim." when the total is 0. | — |

### 1.11 Scan, propose, add, remove (9)
| Function | Line | What it does | Platform dependency |
|---|---|---|---|
| `pkg_script` | 1740 | `package.json` → `scripts[key]` through python3. Returns 1 without python3. | **python3** (Go: `encoding/json`) |
| `port_from_command` | 1752 | Regex `--port[= ]N` or `(^\| )-p N`, 2-5 digits. The `PORT=3000` form mentioned in the comment is **not** implemented. | sed -E |
| `port_from_framework` | 1757 | Substring order: next 3000, vite 5173, astro 4321, remix 3000, nuxt 3000, storybook 6006, rails/puma 3000, django/manage.py 8000. | — |
| `propose_config` | 1771 | Name = lowercased basename with non-`[a-z0-9._-]` as `-`. Package manager by lockfile precedence: pnpm, bun(.lockb only), yarn, npm, bundle, uv, poetry, cargo. Script: first of dev, start, docs, storybook, serve; the command is `<pm> run <key>` only when both exist. Port from the command, then the framework, then 3000. Runtime: mise.toml/.mise.toml → mise, .tool-versions → asdf, .nvmrc → fnm. Default branch from `origin/HEAD`, else the current branch. COPY_FILES: whichever of .env.local, .env and .env.development exist **and** are gitignored. Compose: the first of docker-compose.yml, compose.yaml, compose.yml or docker-compose.yaml; services under the top-level `services:` block at 2-space indent, filtered to postgres/mysql/mariadb/redis/valkey/mongo/elasticsearch/rabbitmq prefixes. Emits a commented conf; `REPO` has `$HOME` replaced by `~`; a Procfile gives `PROCFILE=1`, otherwise TARGETS (or `REPLACE-ME`); `--open` in the script gives OPENS_ITSELF=1; SYMBOL=shippingbox. | git, awk, sed, `date` |
| `add_project` | 1920 | Same naming; dies when the conf already exists (**never overwrites**); writes propose output; deletes the partial file on failure; prints `name⇥path`. | — |
| `remove_project` | 1881 | Loads the project and refuses when running. rm conf; `rm -rf WORK_ROOT` only when it matches `RB_HOME/?*`; removes the name from favourites. Never touches REPO. | rm -rf |
| `scan_repos` | 2002 | `find root -maxdepth 3 -type d -name .git` (excluding node_modules; default `~/Development`), for repos that are not declared (by derived name, or by a literal `"<path>"` in any conf). Emits `name⇥path`. Confs from propose store `~/…`, so the path check misses them; the name check usually catches them. | **find** (Go: WalkDir with a depth limit; on Windows the default root should be `~/development` or configurable) |

### 1.12 Doctor (1)
| Function | Line | What it does |
|---|---|---|
| `doctor_project` | 2024 | Checks: config path; in-repo config noted; REPO/.git; DEFAULT_BRANCH resolves; each COPY_FILES entry exists; INSTALL head on PATH; docker on PATH and the compose file exists (when COMPOSE_SERVICES is set); RUNTIME on PATH (nvm always passes, since it is a shell function); each target's command head on PATH, printed with its **declared** port; gh plus a GitHub remote (informational). Returns 1 on any warn. `main doctor` with no args runs every project, then `report_port_overlaps`, and exits 1 when any failed. A project with a broken conf makes `load_project` die inside the subshell, which counts as rc=1. |

### 1.13 Interactive (3 + cleanup) — see §5
`pick_project` 2150, `pick_branch` 2172, `pick_preset` 2205, `cleanup_worktrees` 2338, `ask` 133.

### 1.14 Dispatch and wire contracts (`main`, 2425)
Every invocation runs `harden_path` and `migrate_bundle_projects` first.

| Subcommand | Output / behaviour | Exit |
|---|---|---|
| `projects` | list_projects rows (6 fields) | 0 |
| `projects-dir` | PROJECTS_DIR | 0 |
| `branches <p>` | 15 fields: `ref age ts owner mine pr ready isDefault isCurrent prNumber subject isRemote checkedOutAt ahead behind` (tab) | 0 |
| `get <p>` | `KEY⇥value` for NAME, REPO, DEFAULT_BRANCH, SYMBOL, INSTALL, COPY_FILES, COMPOSE_SERVICES, COMPOSE_PROJECT, MIGRATE, SEED, RUNTIME, DB_URL_VARS, ALWAYS, PRESETS, OPENS_ITSELF, PROCFILE, IN_REPO, and **TARGETS last**, with newlines as `\001`. Note that PORT_OFFSET, COMPOSE_FILE, PORT_BASE, DB_TEMPLATE and DB_ADMIN_USER are not emitted. | 0 |
| `set <p> KEY [value]` | load_project (so it fails when the conf is already broken), then set_project_key. The value may use `\001` for newlines. Never touches `.runbranch`. | 0/1 |
| `paths <p> [ref]` | `worktrees⇥logs⇥conf⇥repo⇥owner/repo[⇥worktreePathForRef]` | 0 |
| `presets <p>` | one per line | 0 |
| `state <p>` | Not running: adopted rows, or `idle`. Running: `run⇥ref⇥preset⇥started⇥epoch⇥worktree⇥inPlace`, `behind⇥N`, optional `switched⇥branch`, and `target⇥name⇥effectivePort⇥health⇥pid⇥alive` zipped from TARGETS and PIDS. | 0 |
| `favourite <p> on\|off` | Does not validate that the project exists. | 0 |
| `refresh <p>` | `refreshed` on stdout, or `refresh failed` on stderr (exit 0 either way) | 0 |
| `reclaim [<p>]` | | 0 |
| `remove-worktree <p> <ref>` | | 0/1 |
| `run <p> <ref> <preset> [offset] [--in-place]` | The offset must be all digits (no negatives); any order; the last one wins. | 0/1 |
| `update <p>` | Must be running and not in place; saves ref, preset and offset → stop_run → restores PORT_OFFSET, sets IN_PLACE=0 → do_run. | 0/1 |
| `prune-gone <p>` | ends with `pruned⇥N` | 0 |
| `overlaps` | `port⇥projects` | 0 |
| `suggest-offset <p>` | a number | 0/1 |
| `ports` | report_ports (TTY: a formatted table) | 0 |
| `kill-port <pid>` | | 0/1 |
| `check-ports <p> <preset>` | conflict rows + `OFFSET⇥n` | **1 on conflict** |
| `stop <p>` | | 0 |
| `status [<p>]` | exit 1 when nothing is running | 0/1 |
| `cleanup <p>` | interactive | 0 |
| `disk` | report_disk (TTY: an MB/GB summary) | 0 |
| `scan [dir]` | `name⇥path` | 0 |
| `add <repo>` | `name⇥confpath` | 0/1 |
| `remove <p>` | | 0/1 |
| `propose <repo>` | conf text | 0/1 |
| `doctor [<p>]` | | 0/1 |
| `help`, `-h`, `--help` | usage | 0 |
| no args, or `menu` | requires a TTY, else dies with `open Runbranch.app` | |
| unknown, or missing args | usage | **2** |

`die` exits 1 everywhere.

---

## 2. Invariants recorded in comments (rules the rewrite must keep)

### Core promise
- **I-1 (22-23, 435-437, 1682-1683):** Never modify the working checkout. The only things allowed in it are reading refs, copying gitignored files *out of* it, and git-worktree metadata operations. No checkout, no stash. `fetch` only when explicitly asked; no such command exists today.
- **I-2 (669-672):** Create worktrees **detached** at the tip commit, never as a branch checkout. Git refuses a branch checked out twice, and the runner must not hold a ref it might move.
- **I-3 (1878-1880, 1917, config.md:209):** `remove <project>` deletes the conf and `RB_HOME/<project>` only. Never the repository.
- **I-4 (2461-2462):** `set` rewrites only the local conf. Never the in-repo `.runbranch`.

### Paths and state location
- **I-5 (45-57, config.md:16-19):** Never keep projects in the app bundle, because an update replaces it wholesale. An installed app uses `RB_HOME/projects`; a source checkout uses `projects/` beside the script; `RB_PROJECTS_DIR` wins over both.
- **I-6 (74-75):** Bundle-to-RB_HOME migration runs one way only and never overwrites an existing file. RB_HOME wins.
- **I-7 (79-81):** Create the projects dir even when there is nothing to migrate. The app offers to reveal it.
- **I-8 (2430-2432):** The app asks the engine for `projects-dir`; it must never derive it.
- **I-9 (2468):** `paths` exists so the app never hardcodes the layout.
- **I-10 (201-202, 1912, config.md:87-91):** Favourites live in `RB_HOME/favourites`, never in a conf, and are removed when the project is removed.
- **I-11 (94-97):** "Mine" defaults to git's `user.email`; `RB_MY_EMAILS` overrides. Never hardcode addresses.

### Messaging and non-interactive use
- **I-12 (122-123):** Every failure names the command that fixes it. No dialogs; the app shows what the engine prints.
- **I-13 (131-132):** Without a TTY, never block on input. Take the stated default and say so. The cautious default for destructive questions is no.
- **I-14 (156-163):** Do not trust the inherited PATH (a GUI launch gets launchd's minimal PATH). Add the known tool dirs and ask fnm for node. The app also launches through `zsh -lic`; on Windows the equivalent is reading the user's PATH from the registry (HKCU and HKLM Environment), since a GUI-launched process can carry a stale PATH.

### Config loading
- **I-15 (223-224):** Reset every default before each load, so a second load cannot inherit from the first and both layers start clean.
- **I-16 (245-249):** Validate that a config parses **before** applying any of it. A half-applied config reports the wrong error ("sets no REPO" for an unclosed quote).
- **I-17 (262-268):** Layering order: read the local conf for REPO → reset → in-repo `.runbranch` as the base → local conf on top. **The local file wins.**
- **I-18 (277-278):** Expand `~` in REPO again after the second pass.
- **I-19 (288-290, 306-307):** Procfile: ports assigned foreman-style (PORT_BASE + 100·i) and exported as PORT.
- **I-20 (366, config.md:53-54):** In TARGETS only the first three colons are separators; the command may contain colons.
- **I-21 (398-399):** No PRESETS means one preset per target, plus `all` when there is more than one.
- **I-22 (411):** ALWAYS targets come first in every preset, de-duplicated.
- **I-23 (1932-1939, 1967-1968, 1992):** Rewriting a key preserves everything else, **comments included**. It must handle multi-line values (the first version emptied the file on a multi-line TARGETS). Back up before writing, re-load after writing, and restore the backup if the result will not load.
- **I-24 (2436-2438):** The app reads fields through `get`, never by parsing a conf.
- **I-25 (2457):** In `get`, TARGETS is last and newline-encoded as `\001`.

### Ports
- **I-26 (341-348, config.md:45,47):** Ports are declared, not dynamic, because stacks bake origins in (OAuth, CORS, compiled API URLs). A PORT_OFFSET shifts **every** target by the same amount so relative layout survives. `PORTS=stepping` is not implemented; do not implement it silently.
- **I-27 (354-356, 2498-2503):** Runtime paths (state output, health polls, Open URLs) use the **effective** port (declared + offset). `doctor` reports the declared one. Emitting the declared port under an offset once sent the app's Open button and health poll to another project's server, which passed the check while this run was dead.
- **I-28 (1520-1525, 1534-1535):** `load_state` restores PORT_OFFSET and IN_PLACE from the state file but must **not reset** them when reading. Resetting silently discarded a requested offset once and `--in-place` a second time.
- **I-29 (2559-2560):** `update` must carry the run's offset across stop and start, because stop clears the state that holds it.
- **I-30 (1444-1452):** Tell a server its port both ways: substitute `{port}` in the command **and** export `PORT`. When the server ignores PORT, the health check fails on the shifted port and says what to add. That beats refusing to try.
- **I-31 (1321-1323):** `{port}` in the command means `explicit` (a promise); otherwise `env` (offered, might be ignored).
- **I-32 (1411-1416, 1428-1429):** A shifted run that fails, when the command lacks `{port}`, gets the specific "server ignores PORT" explanation plus a suggested (not pasted) `--port {port}` edit.
- **I-33 (973-981):** Take **one** snapshot of all listeners and match against it. Do not spawn a query per port (the offset search probes up to 200 offsets). Pass the snapshot to the caller rather than caching it globally, because callers reap processes based on it and a stale answer is dangerous.
- **I-34 (983-985):** Parse structured listener output, not the human table. Reading the wrong column once reported every port as free.
- **I-35 (990-991):** A socket with a remote endpoint (`->`) is not a listener. Accept `*:p`, `127.0.0.1:p` and `[::1]:p`.
- **I-36 (1061-1069):** Overlap detection compares **effective** ports. Declared ports reported already-separated projects as clashing.
- **I-37 (1076-1078):** Iterate target **names**, never whitespace-split TARGETS.
- **I-38 (1091-1093):** When counting duplicates, de-duplicate full `port+project` pairs, not ports. (`sort -n -u` collapsed every port to count 1.)
- **I-39 (1102-1107):** A suggested offset must clear every port of the project at once, and "free" means both "not claimed by another project" **and** "not currently listened on by anything", including servers Runbranch did not start. The search is limited to 200.
- **I-40 (1130):** When nothing within 200 is free, say so (print 0 and fail). Never suggest a number that clashes.
- **I-41 (1307-1314):** In a port check, this project's **own** Runbranch run is not a conflict, since do_run stops it first. The same project started **outside** Runbranch *is* a conflict, and "Take Over" stays on offer.
- **I-42 (1231-1232):** `ours` in the ports report means this project's own run. Another project's run on the port is still `outside`, a conflict.
- **I-43 (1373-1376):** A port held by another Runbranch run gets the fix `stop <that project>`. A port held by an unknown process gets different advice. Never send the user after the wrong project.
- **I-44 (config.md:142-144):** Overlaps are not surfaced on project rows. They appear only in doctor, `overlaps` and the Ports sheet.

### Process attribution and killing
- **I-45 (1005-1019):** Attribute a port holder by **command line and working directory**. Under RB_HOME it is `ours` (the project is the first path segment); inside a project's REPO it is `outside`; otherwise `unknown`. The command line alone misses `python3 -m http.server`-style launches.
- **I-46 (1165-1172):** `kill-port` refuses any process it cannot attribute to a known project. "Kill whatever is on this port" will eventually be pointed at a database or an editor.
- **I-47 (1171-1172):** A foreign holder gets TERM only (graceful), waits 10s, then fails with the manual `kill -9` as the fix. Never escalate automatically.
- **I-48 (1178-1179):** Existence checks must not treat EPERM as "gone". The script uses `ps -p`. (The poll loop at 1197 still uses `kill -0`, contrary to the rule.)
- **I-49 (1403-1406, 1608-1609):** Every server starts in **its own process group**, and stop signals the **group**. Watchers such as `tsx --watch` respawn a killed child.
- **I-50 (1632-1634, 2093-2094):** After stopping, reap a stray still on our ports **only** when it clearly belongs to this project's worktrees. Never touch the user's own dev server; report it as "left alone on purpose".
- **I-51 (1250-1257, 1270-1271):** Adopt, and show, a run of this project that Runbranch did not start: same shape, flagged adopted, the ref is the checkout's current branch, the start time comes from the process. Nothing invented. Only this project's `outside` holders qualify.

### Runs, health, browser
- **I-52 (1480-1481):** Any HTTP status means up (a 404 on an uncompiled route is still up). Only "no response" is failure.
- **I-53 (1600-1602):** Do not open a browser when `OPENS_ITSELF=1` (duplicate tab) or when `RB_NO_OPEN` is set (tests must not steal focus).
- **I-54 (1674-1684, config.md:174-187):** In-place runs start only the servers: no INSTALL (it writes into a directory being worked in and can move a lockfile), no COPY_FILES, no per-run DB (that would rewrite a real `.env.local`), no migrate or seed, no compose. The ref must equal the checkout's current branch.
- **I-55 (2251-2258):** Detect and report an in-place run whose checkout has since switched branch (`switched` line).
- **I-56 (2229-2237):** `behind` is 0 whenever it cannot be known. Never fail and never print "unknown".
- **I-57 (2545-2549):** `update` = stop + start at the ref's current tip, with the engine (not the app) holding ref, preset and offset.
- **I-58 (2487-2489, 2494):** New state information goes on **new line types**, never as new fields on existing lines (backward compatibility with older app readers). TARGETS and PIDS zip by order.

### Worktrees, copying, deletion
- **I-59 (448-456):** Slugs are lossy. On a collision the second ref gets a `-<digest>` suffix, recorded in `meta/<slug>.ref`. Non-colliding refs keep the readable name. No migration is needed.
- **I-60 (707-709):** Copy COPY_FILES from the checkout on **every** run, not just on create. A stale copy looks like a broken branch.
- **I-61 (722-723, 1900-1904):** Every recursive delete is leashed: worktree deletes only direct children of `WORKTREES`; project deletes only `RB_HOME/<non-empty>`. Use the already computed WORK_ROOT; never rebuild a path by hand (rebuilding caused the "current" vs "state" guard bug).
- **I-62 (1886-1893):** Refuse to remove a running project, since the servers would be orphaned. Ask through the same state functions the rest of the code uses (a hand-built path meant the guard never fired).
- **I-63 (2271-2274, 2284-2285, 2306-2308, config.md:207, 215-217):** Worktree reclamation is based on **gone** (the ref no longer resolves), never **merged** (squash merges look unmerged). A worktree with no meta file is not evidence of death; treat it as idle and never prune it.
- **I-64 (config.md:190-198):** Never auto-prune worktrees on stop. Keeping them is what makes re-runs fast.
- **I-65 (1874-1875):** `add` never overwrites an existing conf.

### Git and PR data
- **I-66 (472-473):** No gh, or no GitHub remote, means PR badges are absent. Not an error.
- **I-67 (499-502):** Merged status must come from GitHub, not `git branch --merged` (squash merges are unreachable).
- **I-68 (486-487):** Carry the PR title and number; prefer the title over the commit subject.
- **I-69 (519-521):** List local branches first, then remote-tracking branches with no local twin. Reviewing a colleague's PR is the main use case.
- **I-70 (524-531):** Flag branches checked out in a user-made (foreign) worktree, since git will refuse them. Exclude the main checkout and our own worktrees.
- **I-71 (550-553):** Measure ahead/behind against `origin/<default>` when it exists, the local default otherwise. A stale local main would claim nothing is behind.
- **I-72 (565-572):** Compute divergence for every ref in one walk (`%(ahead-behind:)`), probing support once against a known ref. An unsupported atom is fatal to the whole listing, so never guess from `git --version`.
- **I-73 (516-517, 639-642):** Missing ahead/behind are **empty**, never 0/0. "No answer" differs from "level with trunk".
- **I-74 (600-601):** (bash detail) for-each-ref needs `%09` for a tab. In Go, prefer `%00` or `%x09` with explicit splitting.
- **I-75 (497, 503-510):** The PR cache is instant when present and refreshes in the background when older than the TTL. Never block a listing on the network, except when no cache exists.

### Install, runtime, infra, DB
- **I-76 (757-760):** Activate the toolchain **inside the worktree** so the branch's own `.nvmrc`/`.tool-versions`/`mise.toml` pin applies.
- **I-77 (792-803):** Translate known install failures into fixes: a 401 from a private registry means `gh auth refresh -s read:packages`; lockfile drift is the branch's own inconsistency, not a launcher bug.
- **I-78 (809-811):** Always pin `docker compose -p`. Otherwise a worktree creates a second compose project with empty volumes and collides on fixed container names.
- **I-79 (854-855):** Run psql **inside** the postgres container. Never require a host client.
- **I-80 (861-868, config.md:104-113):** A per-run DB is Postgres-only and opt-in through the declared DB_URL_VARS. It is created on run start (reused when present), migrated and seeded from scratch, and dropped **with the worktree**, not on stop.
- **I-81 (884):** Truncate DB names to 63 bytes.
- **I-82 (936-938):** Point the worktree at its DB by **rewriting the copied env files**, not by exporting variables (dotenv precedence varies).
- **I-83 (958):** Never drop the base database, whatever the name arithmetic says.
- **I-84 (1737-1739):** (dependency policy) Avoid adding runtime dependencies for JSON; in Go this is free.

### Propose
- **I-85 (1727-1734):** Propose guesses, says so, and comments each guess. A visible wrong value beats a blank file.
- **I-86 (1788-1790):** Try `dev, start, docs, storybook, serve` and name the target after the script found.
- **I-87 (1826-1827):** Parse compose services only from the `services:` block (a naive grep matched volumes).
- **I-88 (1863-1864):** When the repo does not say how to run it, emit an obvious `REPLACE-ME`, never a plausible command that fails later.

### Doctor and reclaim
- **I-89 (2017-2018, config.md:115-118):** Doctor checks everything that would otherwise fail minutes into a run: repo, default branch, COPY_FILES, command heads on PATH, docker, compose file, runtime, gh.
- **I-90 (2651-2652):** Cross-project overlaps are reported by `doctor` with no args, not per project.
- **I-91 (2088-2090):** After a crash, reclaim on demand. A process on our ports running from our worktrees is ours whatever the state says; state naming dead pids is cleared.

### Doc-level decisions (config.md)
- **I-92 (config.md:163-166):** A config is trusted like a repo's postinstall. If the Go port stops executing confs as shell, update this note.
- **I-93 (config.md:99-100):** The app never filters out the default branch or the running branch.
- **I-94 (config.md:157-159):** An in-repo config shares shape, not secrets.

---

## 3. Platform-specific constructs

| Construct | Where | Purpose | Windows equivalent (Go) | macOS equivalent (Go) |
|---|---|---|---|---|
| `#!/usr/bin/env bash`, bash 3.2 | 1, 35 | engine runtime | Native Go binary | Native Go binary |
| `/bin/bash -n file` + `. file` | 251, 260, 274-276 | parse and apply config | Go parser for the conf subset (B1) | Same parser (one code path) |
| `/bin/bash -c "$(prelude)$cmd"` | 1459 | server command | `exec.Command("cmd", "/d", "/s", "/c", cmd)` or `pwsh -NoProfile -Command`; or Git Bash `bash.exe -c` when found. The runtime env is injected via `Cmd.Env`. | `exec.Command("/bin/bash", "-c", cmd)` (keep, for compatibility with existing confs) |
| `eval "$(prelude)$cmd"` in a subshell | 775, 787 | INSTALL/MIGRATE/SEED | Same as above | `/bin/bash -c` |
| `runtime_prelude` (mise/fnm/asdf/nvm) | 761-770 | toolchain | mise: `mise env --json` (or the `%LOCALAPPDATA%\mise\shims` prefix); fnm: `fnm env --json` + `fnm use --install-if-missing`; asdf: unsupported; nvm: nvm-windows cannot be scoped per directory, so warn or refuse | Same `env --json` approach; asdf via `asdf exec`/shims; nvm still needs bash (`bash -c '. ~/.nvm/nvm.sh && nvm use && env'`) |
| `set -m` + `&` (new process group) | 1457-1462 | group kill | Create the process with `CREATE_NEW_PROCESS_GROUP` and assign it to a **Job Object** (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` off, since servers must outlive the engine; `BREAKAWAY_OK` as needed). Because the engine exits after `run`, persist the job's **name** (a named job, e.g. `Local\runbranch-<project>-<target>`), or record the root PID and fall back to walking the tree (Toolhelp32 parent PIDs, PID reuse checked via creation time). | `SysProcAttr{Setpgid: true}` |
| `nohup` + `disown` | 1459, 1461 | survive the engine exiting / a SIGHUP | `DETACHED_PROCESS` or `CREATE_NO_WINDOW` + `CREATE_NEW_PROCESS_GROUP`; do not inherit console handles; do not `Wait` | `Setsid: true` (or Setpgid plus ignoring SIGHUP); release the process (`cmd.Process.Release()`) |
| `>"$log" 2>&1` | 1459 | log | `Cmd.Stdout = Cmd.Stderr = *os.File` (the file handle is inherited) | same |
| `kill -0 pid` (`alive`) | 1464, 1486, 1543, 1613 | liveness | `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `GetExitCodeProcess == STILL_ACTIVE`; match the creation time to defeat PID reuse (store it in state) | `syscall.Kill(pid, 0)`, treating **EPERM as alive** (I-48) |
| `kill -TERM -pgid` / `kill -KILL -pgid` | 1614, 1619 | stop the tree | No SIGTERM. Graceful: `GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pgid)` (needs a shared console; unreliable when detached), or `taskkill /PID /T` without `/F` (sends WM_CLOSE, useless for console apps). Hard: `TerminateJobObject`, or `taskkill /T /F`. In practice: attempt CTRL_BREAK via a helper that attaches to the console, wait up to 12s, then TerminateJobObject. | `syscall.Kill(-pgid, SIGTERM/SIGKILL)` |
| `kill -TERM pid` (strays, kill-port) | 1195, 1642 | graceful single-process kill | as above (CTRL_BREAK or `taskkill /PID`), then report | `syscall.Kill(pid, SIGTERM)` |
| `ps -p pid` | 1180 | existence | `OpenProcess`; `ERROR_ACCESS_DENIED` means it exists | `kill(pid,0)` with EPERM = exists, or `sysctl kern.proc.pid` |
| `ps -o command= -p` / `ps -o pid=,command=` | 1003, 1023, 1640, 2107 | command line | `Win32_Process.CommandLine` via WMI (slow, ~50-200ms, so batch-query every listener at once), or `NtQueryInformationProcess(ProcessCommandLineInformation)` (Win 8.1+, needs PROCESS_QUERY_LIMITED_INFORMATION; works for most non-protected processes) | `sysctl KERN_PROCARGS2` (e.g. via gopsutil), or keep shelling out to `ps` |
| `ps -o lstart=` + `date -j -f '%a %b %d %T %Y'` | 1283-1284 | process start time | `GetProcessTimes` creation FILETIME | `sysctl kern.proc.pid` → `kp_proc.p_starttime`; format STARTED like write_state, or keep the lstart format for app compatibility (check Swift) |
| `lsof -nP -iTCP -sTCP:LISTEN -Fpn` | 986 | listener snapshot | `iphlpapi.GetExtendedTcpTable(AF_INET and AF_INET6, TCP_TABLE_OWNER_PID_LISTENER)` | shell out to `lsof` (present on every Mac), or gopsutil `net.Connections("tcp")`, which uses lsof on darwin anyway |
| `lsof -iTCP:p -sTCP:LISTEN -t` | 969 | one port | the same table, filtered (replace with one snapshot, per I-33) | same |
| `lsof -a -p pid -d cwd -Fn` | 1024 | process cwd | PEB read: `NtQueryInformationProcess(ProcessBasicInformation)` → `ReadProcessMemory` of `RTL_USER_PROCESS_PARAMETERS.CurrentDirectory` (fragile, fails for elevated or protected processes; handle WOW64). Alternative: attribute via the image path and command line only, and accept more `unknown`. | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` via cgo, or keep lsof |
| `stat -f %m` | 506 | mtime | `os.Stat().ModTime()` | same |
| `date +%s`, `date '+%Y-%m-%d %H:%M:%S'`, `date '+%Y-%m-%d'` | 507, 583, 1513-1514, 1840 | timestamps | `time.Now().Unix()`, `Format("2006-01-02 15:04:05")` | same |
| `/usr/bin/sed -i '' -E` | 945 | in-place env rewrite | Go line rewrite: read, replace the lines where `^VAR=`, write atomically. Preserve CRLF when present. | same |
| `sed`, `awk`, `tr`, `cut`, `grep`, `sort`, `head`, `tail`, `wc`, `seq` | throughout | text | Go strings/regexp/sort | same |
| `cksum` | 444 | digest | Hand-rolled POSIX CRC (B3) | same |
| `cp -R` | 87, 712 | copy files | Go recursive copy (preserve mode where it can; fix the dir-nesting quirk deliberately or keep it) | same |
| `rm -rf` | 733, 1907 | delete | `os.RemoveAll`, after clearing read-only attributes (git object files are read-only on Windows); long paths need the `\\?\` prefix or the `LongPathsEnabled` manifest | `os.RemoveAll` |
| `mv tmp file` | 217, 492, 1915 | atomic replace | `os.Rename` (MoveFileEx REPLACE_EXISTING); can fail when the target is open elsewhere, so retry | same |
| `$$` temp names | 214, 485 | uniqueness | `os.CreateTemp` in the same dir | same |
| `du -sk` / `du -sh` | 2322, 2346 | size | WalkDir summing sizes (optionally `GetCompressedFileSizeW`); de-duplicate hardlinks via file ID (`GetFileInformationByHandle`) to match du | WalkDir + `Stat_t.Blocks*512`, de-duplicated by inode |
| `find -maxdepth 3 -name .git -not -path */node_modules/*` | 2005 | scan | WalkDir with a depth limit and SkipDir on node_modules | same |
| `open "$url"` | 1604 | browser | `rundll32 url.dll,FileProtocolHandler <url>` or `ShellExecuteW("open")`; not `cmd /c start` (it mangles `&`) | `exec.Command("open", url)` |
| `open -t file`, `open file`, `open -a Docker`, `open Runbranch.app` | 256, 823, 1926, 2659 | fix text | Fix strings become `notepad file` / `start "" "Docker Desktop"` etc. Make every fix string per-OS. | unchanged |
| `xcode-select --install` | 1663 | fix text for git | `winget install Git.Git` | unchanged |
| `curl -s -o /dev/null -m 3 -w %{http_code}` | 1487 | health | `net/http` client, 3s timeout, `CheckRedirect: ErrUseLastResponse` | same |
| `python3` (pkg_script, set_project_key) | 1744, 1950 | JSON, config rewrite | Go `encoding/json`; Go rewriter | same |
| `[ -t 1 ]`, `read -r` | 107, 145 etc. | TTY and prompts | `golang.org/x/term.IsTerminal(os.Stdout.Fd())` (works for a Windows console) | same |
| ANSI colours | 110-111 | colour | enable VT mode via `SetConsoleMode` | nothing needed |
| `harden_path` dirs | 168-170 | PATH | Windows: `%LOCALAPPDATA%\Microsoft\WinGet\Links`, `%ProgramFiles%\Git\cmd`, `%ProgramFiles%\Docker\Docker\resources\bin`, `%APPDATA%\npm`, `%LOCALAPPDATA%\pnpm`, `%USERPROFILE%\scoop\shims`, `%LOCALAPPDATA%\mise\shims`, `%USERPROFILE%\.local\bin`, plus a PATH re-read from the registry | keep the list |
| `.app` bundle path detection | 60 | projects dir | detect an install dir (Program Files / LocalAppData\Programs) or a build-time flag | keep |
| `HOME`, `~/.runbranch` | 43 | RB_HOME | `os.UserHomeDir()` → `%USERPROFILE%\.runbranch` (or `%LOCALAPPDATA%\runbranch`; decide, and document) | `~/.runbranch` |
| String path comparisons (`$RB_HOME/*`, `$WORKTREES*`, `path == repo`, `index(path, ours)`) | 539, 729, 1028, 1043, 1642, 1907, 2109 | attribution and leashes | Normalise with `filepath.Clean`, compare case-insensitively (`strings.EqualFold`), convert `/`→`\` from git output, resolve 8.3 short names (the scratch path here is `JANEDO~1` for a user named `jane.doe`) via `GetLongPathName` | `filepath.EvalSymlinks` + Clean (`/private/var` vs `/var` also bites on macOS) |
| `docker compose`, `docker exec … psql` | 814, 897 | infra | Same CLI (Docker Desktop for Windows); remember `docker.exe` | same |
| `gh … --jq … @tsv` | 488-490 | PR list | same CLI; or parse `--json` output in Go and drop `--jq` | same |
| `git` (all) | throughout | git | `git.exe`; paths in porcelain output are `C:/…`; `core.longpaths=true` may be needed for worktrees containing node_modules | same |
| `PORT=n cmd` prefix (Procfile) | 319 | env | set PORT through `Cmd.Env` and drop the prefix; the command then runs under any shell | same (cleaner too) |
| env var `PORT` export | 1458 | port hint | `Cmd.Env` | same |

---

## 4. Concurrency, timing, retries, background work

| Item | Where | Behaviour |
|---|---|---|
| PR cache TTL | 100, 503-510 | `RB_PR_TTL` default 900s, compared to the file mtime. With no cache the refresh is **synchronous** (blocks the listing on `gh`). When stale, a **fire-and-forget** background refresh (`( refresh & )`, detached from the caller's stdout) writes through a temp file and an atomic `mv`, so readers never see a partial file. The Go port runs a detached child (`runbranch refresh-pr-cache`) or a goroutine that the engine waits for only when it is long-lived. A short-lived CLI that exits must spawn a detached process, or the refresh dies with it. |
| gh limit | 488 | 300 PRs, `--state all`. |
| Server start | 1457-1475 | Targets start **sequentially**, each followed by a fixed **1s sleep**, then a `kill -0` "exited immediately" check (shows tail -20 of the log). |
| State write | 1562 | Written after **all** servers start and **before** health checks, so a crash mid-wait leaves state behind, which reclaim can clean up. |
| Health polling | 1482-1497, 1573 | Per target, **sequentially in target order**: timeout **240s**, interval **2s** (the timer counts sleeps only; real elapsed time includes up to 3s per curl, so the worst case is about 600s per target), curl max time **3s**, success = any HTTP code other than 000. Progress messages at 20, 60 and 120s. Before each probe, the target's own pgid leader is checked (`kill -0`) and a dead one returns 2 ("exited while starting"). The URL is `http://localhost:<effective port><health or />`. `localhost` may resolve to ::1 first. curl falls back to IPv4; in Go, dial both (the default Dialer does Happy Eyeballs). |
| Failure handling | 1574-1590 | The first failing target prints tail -25 of its log, then `stop_run quiet` (kills every started group), then dies. |
| kill_group | 1610-1620 | TERM to the group → poll the leader every 1s for **12s** → KILL to the group. |
| kill_port_holder | 1195-1200 | TERM → poll every 1s for **10s** → fail (no KILL). |
| Stray reaping in stop_run | 1635-1646 | Single TERM, **no wait, no KILL** for stray worktree processes. |
| reclaim | 2105-2115 | Uses kill_group (12s + KILL) per stray. |
| Offset search | 1118-1129, 1332-1341 | Up to 200 iterations over one listener snapshot, no sleeps. |
| Listener snapshot cost | 973-976 | lsof takes ~29ms whether it is asked about one port or all. The snapshot is taken once per command, with a fresh one for every operation. |
| Attribution cost | 1036-1047 | For each non-RB_HOME holder, loads every project conf (a bash subshell each). O(holders × projects). In Go, load all projects once per command. |
| Blocking external steps (no timeouts) | 787, 828, 840, 850, 897 | INSTALL, `docker compose up -d --wait` (uses compose's own healthcheck wait, no runbranch timeout), MIGRATE, SEED, psql and git all run with **no timeout**. `docker info` has none either. |
| Background process lifetime | 1458-1461 | Servers outlive the engine (nohup plus disown). The engine is short-lived per command; all later control goes through the state file plus PIDs (= PGIDs). The Go port needs a PID-reuse guard (store the start time per pid), since the state file can outlive a reboot. |
| Races | — | No locking on the state file, favourites, or prcache (only the temp-then-mv pattern). Two concurrent `run`s of the same project would race. The app serialises calls today; consider an advisory lock file per project (`LockFileEx` / `flock`). |
| Non-TTY prompts | 133-142 | Never block; the default answer is printed. |

---

## 5. Interactive-mode features (lower priority for the port)

All are reached through `runbranch.sh` with no args or `menu` (TTY required, 2657-2670), or through `cleanup`.

| Feature | Where | Behaviour |
|---|---|---|
| Menu flow | 2657-2670 | Pick a project → if it is running: print_status, then "Stop it?" (default **no**) → exit. Otherwise pick a branch → pick a preset → do_run. |
| `pick_project` | 2150 | Numbered list `N. display-name  repo(dim)`. Auto-selects when there is exactly one project. Empty input, non-numeric input or out-of-range input cancels (exit 0). |
| `pick_branch` | 2172 | Collects branch data into `WORK_ROOT/branches` (a file, left behind). **Filters**: unless it is the default branch, hides PR state MERGED and anything whose last commit is older than a week (604800s). It does not hide remote-without-PR or apply mine-only; those are app filters. Tags: `[default]`, `[<pr state lowercase>]` (not on default), `[owner]`, `[ready]`, plus age. Numbered choice; empty cancels. |
| `pick_preset` | 2205 | Auto-selects when there is only one. Inline prompt `1 name  2 name  [1]:`, where empty means 1. |
| `ask` | 133 | `[Y/n]` / `[y/N]`; an answer starting with y or n; empty takes the default; anything else is **no**. Used by do_run ("Stop it and start this one?", default yes) and the menu ("Stop it?", default no). |
| `cleanup_worktrees` | 2338 | Lists worktrees with `du -sh` sizes, marks the running one "(running — stop it first)", accepts space-separated numbers, skips the running one, removes the rest (`worktree remove --force` or the leashed rm), then runs prune. **Does not drop per-run DBs or delete meta files**, unlike remove_worktree_for, so it leaks both. The app uses `prune-gone` / `remove-worktree` instead. |
| TTY-only formatting | 2579-2586, 2616-2629 | `ports` prints a column table; `disk` prints MB per worktree plus a GB total and "not in use". Non-TTY output is raw TSV (the app contract). |
| `print_status`, `status` | 1705, 2602 | Human-readable; `status` with no args loops over every project. |
| Colours | 107-114 | TTY and no NO_COLOR only. |

---

## 6. Latent bugs and doc drift found while reading (decide: fix in the port, or keep for parity)

1. `collect_branch_data` ready flag: the awk `slug()` does not strip `origin/`, and it ignores digest slugs, so remote refs are never `ready` (619, 649).
2. `check_ports` prints `OFFSET⇥201` when no offset is free (1332-1342). The comment says overridable is 1/0; the code emits explicit/env (1159-1160 vs 1324).
3. `check_ports` offset search ignores other projects' declared ports; `suggest_offset` does not (1116 vs 1337).
4. `kill_port_holder` polls with `alive` (kill -0), contradicting its own EPERM comment (1197).
5. `kill_group` stops polling as soon as the **leader** dies and then skips KILL for surviving group members (1616).
6. `stop_run` never reaps in-place strays (they match `$WORKTREES` only) and sends a single TERM without follow-up (1642).
7. `drop_run_database` on the remove-worktree path uses an empty COMPOSE_PROJECT when the conf does not set one (824 vs 856, 954).
8. `prune_gone_worktrees` and `cleanup_worktrees` do not drop per-run DBs; `cleanup` also leaves meta files (2288, 2363).
9. `db_source_url` returns 0 from the first existing file even when the var is absent there, so later COPY_FILES are never searched (879).
10. `setup_run_database` sed uses the `#` delimiter, which breaks on `#`, `&` or `\` in URLs (944-945).
11. `set_project_key` does not escape `"`, `$` or backticks in values; the key validation glob accepts `AB<anything>` (1945, 1965).
12. `preset_targets` accepts any string as a target name, so `run p typo` starts an empty command (421-422).
13. `cp -R` into an existing directory nests it (712).
14. `port_holder_owner` REPO substring match: `/a/foo` claims processes in `/a/foobar` (1043).
15. `reclaim_project` returns a count as the exit status (overflows at 256) and treats the holder pid as a pgid (2113, 2127).
16. `port_from_command` comment claims `PORT=3000` support; it is not implemented (1751-1753).
17. `handle_migrations` says "mutates the shared database" even with a per-run DB (839).
18. `port_holder_project` is dead code (1053).
19. `config.md:83` documents `RB_OTHER_LIMIT` (default 80); neither the script nor the Swift sources reference it.
20. `load_project` rejects a REPO whose `.git` is a file (a repo that is itself a linked worktree or submodule) (287).
21. Adopted-state `STARTED` uses the `ps lstart` format; normal state uses `YYYY-MM-DD HH:MM:SS` (1283 vs 1513).
22. `get` omits PORT_OFFSET, COMPOSE_FILE, PORT_BASE, DB_TEMPLATE and DB_ADMIN_USER, although `set` can write them (2440-2458).
