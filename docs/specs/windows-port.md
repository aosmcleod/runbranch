# Spec: Runbranch on Windows 11

Status: **draft for review** · Written 2026-09-24 · Branch `windows-port`

Appendices, generated from a full read of v1.5.1 (`91e1cea`) and treated as
part of this spec:

- [windows-port-engine-contract.md](windows-port-engine-contract.md) — every
  subcommand's arguments, stdout, stderr and exit code, pinned to the Swift
  parsers. **The Go engine must satisfy it.**
- [windows-port-engine-internals.md](windows-port-engine-internals.md) — all
  104 engine functions, 94 invariants recorded in comments, and the
  platform-construct table.
- [windows-port-ui-map.md](windows-port-ui-map.md) — the Mac view hierarchy,
  logic that lives in Swift, and the Mac → WinUI 3 mapping.

---

## 1. Summary

One engine, two native windows over it.

```
                 ┌──────────────────────────┐
  app/  (Swift)  │  SwiftUI, macOS 26        │──┐
                 └──────────────────────────┘  │   same subcommands,
                 ┌──────────────────────────┐  ├── same TSV on stdout,
  windows/ (C#)  │  WinUI 3, Windows 11      │──┘   same FAILED/Fix: on stderr
                 └──────────────────────────┘
                              │
                 ┌──────────────────────────┐
  engine/ (Go)   │  runbranch / runbranch.exe │  ← replaces runbranch.sh
                 └──────────────────────────┘
```

The sharing boundary already exists: `app/Engine.swift` is the only file that
talks to the engine, and the app only parses what the engine prints. So the
engine is rewritten once in Go, behind the **same contract**, and each UI stays
native. The Mac app needs one change (which file it runs), and the Windows app
is a structural port of the Mac one.

## 2. Scope

**In**

- `engine/` — a Go reimplementation of `runbranch.sh`, byte-compatible with
  the v1.5.1 contract on macOS and Windows, including the interactive `menu`
  and the human-readable `status`/`doctor`/`ports`/`disk` output.
- `windows/` — a WinUI 3 app with the same window, sidebar, branch list, run
  strip, action bar, toolbar, sheets and tray mode as the Mac app.
- The Mac app runs the Go engine when it is bundled, and falls back to
  `runbranch.sh` otherwise.
- `tests/engine.sh` runs against either engine, on either OS.
- A GitHub Actions workflow: the engine suite on macOS and Windows, plus a
  Windows app build.

**Out, deliberately**

- **Removing `runbranch.sh`.** It stays as the Mac fallback until the suite
  passes against the Go engine on a Mac. Then it is deleted in its own change.
- **Windows code signing and installer.** Built for this machine: an
  unpackaged folder you run from `dist\windows\`. Signing is not needed for
  the updater (F10): SmartScreen only flags files that carry a browser's
  Mark of the Web, and the app downloads its own update.
- **Screenshot and self-test tooling** (`Screenshot.swift`, `tests/ui.sh`)
  on Windows.
- **asdf and nvm on Windows.** No per-directory Windows equivalent exists;
  `doctor` says so. mise and fnm work on both platforms.

**Deferred**

- WSL-hosted repositories.
- Listing every running project in the tray (Mac parity first).
- The bug fixes marked *parity* in §4.7.

## 3. Repository layout

```
engine/                      Go module, the shared engine
  cmd/runbranch/main.go      dispatch, usage
  internal/config/           .conf parser and writer, projects dir, favourites
  internal/gitx/             branches, worktrees, PR cache (gh), slugs, cksum
  internal/run/              run / stop / update / state / health / infra / DB
  internal/ports/            listeners, attribution, check-ports, offsets
  internal/proc/             process start, tree kill, liveness, cmdline, cwd
                             (proc_darwin.go, proc_windows.go)
  internal/disk/             disk, prune-gone, cleanup, reclaim
  internal/scan/             scan, propose, add, remove, doctor
  internal/ui/               step/ok/info/warn/die, TTY, colour, prompts
app/                         Mac app (unchanged apart from Engine.swift)
windows/Runbranch/           WinUI 3 app (C#, .NET 10)
windows/make-app.ps1         build engine + app into dist\windows\Runbranch
runbranch.sh                 kept as the macOS fallback, frozen
tests/engine.sh              runs against RB_TEST_ENGINE (default: Go binary if built)
.github/workflows/test.yml   macOS + Windows
```

## 4. The engine

### 4.1 Contract

The contract appendix is normative. In particular:

- Every machine subcommand prints the same TSV, in the same field order, LF
  line endings, UTF-8 — **including on Windows**. Paths in output use the OS's
  native separators; the apps treat paths as opaque strings.
- Failure is `FAILED <msg>` on stderr, optionally followed by a `Fix:` block,
  and exit 1. Usage errors exit 2.
- Streamed commands (`run`, `update`, `stop`, `remove-worktree`, `remove`)
  write whole lines and flush after each.
- Server logs are truncated when their server starts. The apps treat a log
  that got shorter as a restart.
- Worktree directory names use the same slug and the same **POSIX `cksum`**
  digest, so existing worktrees keep their names.
- On-disk state is compatible in both directions on macOS: a run started by
  `runbranch.sh` can be stopped by the Go engine, and the reverse.

### 4.2 Config files

Today a `.conf` is bash that the engine sources. The Go engine parses a
**strict subset**, which covers `example.conf`, everything `propose` and `set`
write, and everything `docs/config.md` documents:

- `KEY=value`, `KEY="value"`, `KEY='value'`, with `export ` allowed as a prefix
- double-quoted values may span lines, and may contain `\"`, `\\` and `\$`
- `$HOME`, `${HOME}` and a leading `~` expand; nothing else does
- `#` comments, whole-line or trailing, are ignored and preserved on write
- the in-repo `.runbranch` overlays the local config exactly as now

Anything else — command substitution, conditionals, other variables — is a
load error that names the file and line. `doctor` reports it, and the project
is omitted from `projects`, exactly as a bash syntax error is today.

`set` rewrites only the target key's line or lines, escapes `"`, `\` and `$`,
keeps comments, and still re-loads the file and restores the backup if the
result will not load.

### 4.3 Commands and shells

| | macOS | Windows |
|---|---|---|
| TARGETS / INSTALL / MIGRATE / SEED | `/bin/bash -c <cmd>` (unchanged) | `cmd.exe /d /s /c <cmd>` |
| Procfile `PORT=n cmd` | env var, not a prefix | env var |
| `{port}` substitution | unchanged | unchanged |
| RUNTIME=mise | `mise env` applied to the child's environment | same (`mise env --json`) |
| RUNTIME=fnm | `fnm env` + `fnm use --install-if-missing` | same |
| RUNTIME=asdf / nvm | bash prelude, unchanged | `doctor` error: not available on Windows |
| PATH hardening | Homebrew, /usr/local, pnpm, Docker.app | WinGet Links, Git, Docker Desktop, npm, pnpm, scoop, mise shims |

### 4.4 Processes

| Need | macOS | Windows |
|---|---|---|
| Start a server that outlives the engine | `Setpgid`, detached, stdin null, log as stdout+stderr | `CREATE_NEW_PROCESS_GROUP \| DETACHED_PROCESS \| CREATE_NO_WINDOW`, log handle inherited |
| Stop the whole tree | TERM the group, wait 12 s, KILL the group — **and** any survivors, not just the leader | Graceful attempt, wait, then kill every descendant of the recorded root (a Toolhelp32 parent walk, guarded by creation time), or a Job Object when one can be reopened. The implementer verifies which one works once the engine has exited. |
| Is it alive | `kill(pid, 0)`, EPERM = alive | `OpenProcess` + `GetExitCodeProcess`; the recorded creation time defeats PID reuse |
| Who listens on a port | `lsof` snapshot (always present on macOS) | `GetExtendedTcpTable`, IPv4 + IPv6 |
| Command line of a pid | `ps -o command=` | `NtQueryInformationProcess(ProcessCommandLineInformation)` |
| Working directory of a pid | `lsof -d cwd` | PEB read; on failure, fall back to the command line and image path, and accept `unknown` |
| Open a URL | `open` | `ShellExecuteW` |

The state file gains a start-time field per target, appended as a new
trailing field so both engines read each other's files.

### 4.5 Locations

- `RB_HOME` defaults to `~/.runbranch` on macOS and `%USERPROFILE%\.runbranch`
  on Windows.
- The projects dir is `RB_HOME/projects`, unless the binary sits in a Runbranch
  checkout (an ancestor directory holding `projects/example.conf`), in which
  case it is that checkout's `projects/`. This keeps today's development
  behaviour and today's "never inside an app bundle" rule. `RB_PROJECTS_DIR`
  still wins.
- On Windows, every path the engine compares is cleaned, long-name-resolved
  (this machine's temp dir is `JANEDO~1` for a user named `jane.doe`) and compared case-insensitively.

### 4.6 Tests

- `tests/engine.sh` takes `RB_TEST_ENGINE`. It runs unchanged against
  `runbranch.sh`, and against the Go binary on macOS and Windows (Git Bash).
  The fixture server uses whichever of `python3`/`python` really runs.
- Assertions that pin a bug being fixed (§4.7) change with the fix, and say so.
- Go unit tests cover the config parser and writer, cksum, slugs, preset
  expansion, TSV formatting, and the Windows process and port layer.

### 4.7 Known bugs: fixed or kept

**Fixed in the Go engine** (data loss, or plainly wrong):

| # | Bug | Source |
|---|---|---|
| 1 | `set` deletes lines after a value with a trailing comment | contract §7.1 |
| 2 | `set` writes `"`, `$` and backticks unescaped | internals §6.11 |
| 3 | `get` omits `PORT_OFFSET`, so the editor loads it empty | contract §7.2 |
| 4 | `remove-worktree` fails silently for per-run-DB projects | contract §7.6 |
| 5 | Remote branches are never `ready` | contract §7.9 |
| 6 | Group kill skips KILL when the leader dies before its children | internals §6.5 |
| 7 | `kill-port` polls with a check that fails on EPERM | internals §6.4 |
| 8 | `/a/foo` claims processes running in `/a/foobar` | internals §6.14 |
| 9 | `cp -R` into an existing directory nests it | internals §6.13 |
| 10 | `tests/engine.sh:464` passes by accident | contract §7.12 |

**Kept for parity** (behaviour the app depends on, or a product call; logged as
follow-ups): unknown preset as a single target; `check-ports` offset relative
to the declared port; a state file's offset winning on switch; every
`DB_URL_VARS` pointing at the first URL; in-place runs attributed `outside`;
email substring matching; the `ps lstart` format in adopted state.

## 5. The Mac app

- `Engine.scriptPath` looks for `RB_ENGINE`, then a bundled `runbranch` binary,
  then the bundled `runbranch.sh`. Nothing else in the app changes.
- `make-app.sh` builds a universal `runbranch` (arm64 + x86_64, `lipo`) when
  `go` is on PATH, and bundles it next to `runbranch.sh`. Without Go it warns
  and bundles only the script.
- **Unverified from this machine.** CI runs the engine suite on macOS; the app
  itself needs a local build and a look.

## 6. The Windows app

### 6.1 Stack

- C#, .NET 10, WinUI 3 (Windows App SDK, latest stable), unpackaged and
  self-contained, x64.
- Windows Community Toolkit (`SettingsCard`/`SettingsExpander`, `Segmented`)
  and `H.NotifyIcon.WinUI` for the tray. No other dependencies.
- Settings as JSON in `%LOCALAPPDATA%\Runbranch\settings.json`.
- The engine ships next to the exe. `RB_ENGINE` overrides it, as on the Mac.

### 6.2 Structure mirrors the Mac files

| Mac | Windows |
|---|---|
| `Engine.swift` | `Engine.cs` — run, capture, failure, stream (Runner), health monitor, editors |
| `Model.swift` | `Model.cs` — the same parsers, field for field |
| `ContentView.swift` | `MainWindow.xaml(.cs)` — shell, sidebar, detail, toolbar, snapshot/cache, start flow |
| `Views.swift` | `Views/` — `RunStrip`, `BranchRow`, `ProjectRow`, `Badge`, `SymbolPicker`, `WelcomeView` |
| `RunSheet.swift` | `Dialogs/RunDialog`, `Dialogs/LogsDialog` |
| `ScanSheet.swift` | `Dialogs/ScanDialog` |
| `ProjectEditor.swift` | `Dialogs/ProjectEditorDialog` |
| `Ports.swift` | `Dialogs/PortConflictDialog`, `Dialogs/PortsDialog` |
| `Disk.swift` | `Dialogs/DiskDialog` |
| `Updates.swift` | `Updates.cs` + `tools/install-update.ps1` — check, download, verify, swap, What's new (F10) |
| `App.swift` | `App.xaml.cs`, `Tray.cs`, `AboutDialog` |

Logic in Swift beyond presentation — branch filter, snapshot and cache,
selection rules, start flow with port check, health polling (5 s, 3 s timeout),
log tailing (256 KiB, 5,000 lines, 1.5 s), timers, editor dirty-tracking,
disk summaries, version comparison, What's new — is ported rule for rule from
ui-map §4.

### 6.3 Component mapping

Full table in ui-map §3. The headline choices:

| Mac (Tahoe) | Windows 11 |
|---|---|
| Window with unified toolbar | `Window` + Mica backdrop + `TitleBar` (title, subtitle, pane toggle, search, buttons) |
| `NavigationSplitView` sidebar, three sections | `NavigationView` Left mode; Running / Favourites / Projects as collapsible parents |
| Liquid Glass run strip | Card (`CardBackgroundFillColorDefaultBrush`, 8 px radius) |
| `.glass` / `.glassProminent` buttons | `Button` / `AccentButtonStyle`; destructive = red critical-fill style |
| Toolbar filter / refresh / ••• | Subtle buttons with `MenuFlyout`s in the title bar |
| `.searchable` | `AutoSuggestBox` in the title bar |
| Sheets (one at a time) | `ContentDialog` (one at a time), sizes raised to match |
| Grouped `Form` editor | `SettingsCard` groups (the Windows Settings look) |
| Segmented picker | Toolkit `Segmented` |
| SF Symbols | Segoe Fluent Icons, falling back to Fluent UI System Icons; configs keep SF names |
| Menu bar status item | Notification-area icon with the same menu |
| Finder, Dock, menu bar wording | File Explorer, taskbar, notification area |

### 6.4 Build and run

```powershell
.\windows\make-app.ps1           # go build + dotnet publish -> dist\windows\Runbranch\
.\dist\windows\Runbranch\Runbranch.exe
```

## 7. Front-end decisions

Approved 2026-09-24. ui-map §5 has the reasoning.

| # | Decision | Outcome |
|---|---|---|
| F1 | Sheets | `ContentDialog` for all of them, sized like the Mac sheets — **approved** |
| F2 | Sidebar | `NavigationView` with collapsible Running / Favourites / Projects — **approved** |
| F3 | Menu bar | None. About, Check for updates, Add, Scan and Projects folder go in the ••• menu — **approved** |
| F4 | Shortcuts | Ctrl for ⌘; F5 full refresh, Ctrl+R reload, Shift+F5 stop, Ctrl+F search, Ctrl+1–9 in sidebar order |
| F5 | Where it lives | Taskbar only (default) / taskbar and notification area / notification area only; closing in a tray mode hides to the tray |
| F6 | Visual language | **Fluent** (stock WinUI controls, Mica, card run strip, accent buttons; badge colours kept from the Mac) on a strict grid: 28 px control height, 13 px body text, 11 px captions, 8 px spacing unit, one icon size per role (16 px sidebar and toolbar, 12 px badges). A Mac-like restyle was mocked and declined. |
| F7 | Engine errors | `ContentDialog`, like the Mac alert (parity) |
| F8 | Tray menu | Mac parity: the selected project, Stop, Open, Quit, plus the health line the Mac never filled in |
| F9 | Open worktree in | VS Code, Cursor, Zed, Windows Terminal, Claude Code (in Terminal), File Explorer |
| F10 | Updates | **Same as the Mac**: GitHub latest release → asset `Runbranch-<ver>-windows-x64.zip` → SHA-256 from the release digest → a PowerShell helper waits for the app to exit, swaps the folder, relaunches. `windows/make-app.ps1 -Release` produces the zip; `docs/VERSIONING.md` gains the upload step. |
| F11 | Search | Always visible in the title bar; collapses to an icon below ~900 px |
| F12 | Appearance | Follows the Windows app theme live by default; ••• ▸ Appearance ▸ Use system setting / Light / Dark overrides it (setting `appearance`). Caption buttons, Mica and dialogs follow the effective theme; the tray icon follows the *taskbar* theme. Added 2026-09-25 after the first run opened light on a dark system with unreadable caption buttons. The Mac has no equivalent because macOS apps follow the system without one. |
| F14 | Title bar height | Tall caption bar (48 px, `TitleBarHeightOption.Tall`) so the caption buttons match a header that holds search and toolbar buttons; 28 px controls centred in it. Added 2026-09-25. |
| F15 | Header buttons | Pane toggle, filter, refresh and ••• styled as caption buttons: the same size, square, borderless, the same hover/pressed fills and glyph colour, butted against the caption buttons so the top edge reads as one set. Search stays a 32 px field, centred. Added 2026-09-25. |
| F16 | Install | A zip: extract anywhere, run `Runbranch.exe`. No installer, no admin. Decided 2026-09-25. |
| F17 | No admin, ever | Long paths without the machine-wide registry switch: the engine passes `-c core.longpaths=true` to every git it runs, deletes through `\\?\` paths, and the app manifest is long-path aware; `doctor` no longer asks for admin, and an install that fails on a long path says so. Updates swap the folder with `runbranch.exe install-update`, not a PowerShell script, because script policy is often locked down on work machines. Decided 2026-09-25. |
| F18 | Releases | Publishing a GitHub release builds and attaches the Windows zip in CI; the Mac disk image stays a local step, since the signing identity lives on the Mac. A manual run of the workflow picks windows, mac or both. Each app treats a release without its own download as "nothing to offer", so a release can ship one platform or both. Decided 2026-09-25. |
| F19 | Build size | Only the Windows App SDK components the app uses (no Windows AI, search or widgets); .NET trimming only if the app survives it end to end. Decided 2026-09-25. |
| F20 | Button order | In every footer the action the sheet exists for is rightmost and the only accented button; Cancel is always neutral and to its left. A destructive primary (stop, remove, take over) is red instead of accent, and Return never triggers a destructive action unless it is the sheet's routine resolution (Stop and switch). Stock `ContentDialog` buttons are used only for a single OK, because with two they put the primary on the left and accent the default. Added 2026-09-25 after Remove showed red Remove on the left and a blue Cancel on the right. |
| F13 | Chips and heights | Every chip one fixed height (~18 px from the 11 px caption line), hugging its content, centred, identical with or without an icon; every control 28 px; rows sized by content with one padding token. Added 2026-09-25 after chips rendered at uneven heights. |

## 8. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A Mac user's `.conf` uses bash beyond the subset | Medium | `doctor` names the line; `runbranch.sh` remains the fallback |
| Stopping node trees on Windows leaves strays | Medium | Descendant walk plus creation-time guard; `reclaim` at launch; tested with a watcher that respawns |
| Windows attribution weaker (no reliable cwd) | High | PEB read, then command line; the UI already has an "unknown" wording |
| Long paths break worktree deletes | High on this machine | `\\?\` paths in the engine; `doctor` warns when `LongPathsEnabled` is 0 and says how to turn it on |
| Mac app untested here | Certain | CI for the engine; a local Mac build before merge |
| Defender slows installs in worktrees | High | `doctor` mentions Dev Drive; not something the engine can fix |

## 9. Verification

1. `go test ./...` on Windows.
2. `tests/engine.sh` against the Go binary on Windows (Git Bash) — every
   assertion passes or is explained.
3. Build the Windows app and drive it: welcome → scan → add this repo's
   fixture-like project → start a branch → strip turns healthy → logs → stop →
   ports → disk → editor save → tray mode.
4. CI green on macOS (both engines) and Windows.
5. On a Mac, by you: `./make-app.sh` and one run end to end.
