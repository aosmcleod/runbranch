# Runbranch — Mac UI inventory and WinUI 3 port map

Source: `app/*.swift` (all 12 files read in full), `README.md`, `docs/img/*.png` (8 screenshots viewed).
Line numbers are `file:line` against commit 91e1cea (v1.5.1).

Legend for engine calls: `E(x y)` = `runbranch.sh x y` via `Engine.capture` (stdout + exit code),
`F(x y)` = via `Engine.failure` (stderr captured, returned as an error string when exit != 0),
`R(x y)` = streamed via `Runner` into the Run sheet.

---

## 1. View hierarchy

### 1.1 Scenes and app shell

| Element | Where | What it shows / does | State / inputs | Engine |
|---|---|---|---|---|
| `RunBranchApp` `@main` | App.swift:348 | One `Window("Runbranch", id: "main")` scene (not WindowGroup — single instance; `openWindow(id:"main")` focuses it). `.windowResizability(.contentMinSize)`. `NSWindow.allowsAutomaticWindowTabbing = false` (App.swift:356). | — | — |
| `AppDelegate` | App.swift:342 | `applicationShouldTerminateAfterLastWindowClosed` = true only in Dock-only mode; otherwise app stays alive windowless. | `Presentation.current` | — |
| `Presentation` enum | App.swift:35 | `dock` ("Dock Only", default), `both` ("Dock and Menu Bar"), `menuBar` ("Menu Bar Only"). Persisted in UserDefaults key `presentation`. menuBar => activation policy `.accessory` (no Dock icon, no app menu bar). | UserDefaults | — |
| `ContentView` root | ContentView.swift:241 | If `projects.isEmpty && !loadingProjects` → `WelcomeView`; else `NavigationSplitView { sidebar } detail: {…}`. Frame min 780×440, ideal 820×540 (ContentView.swift:266). `.toolbarBackgroundVisibility(.automatic, for: .windowToolbar)` (273). Toolbar hidden entirely when no projects (474). | see §4 | startup `.task` (274): `E(reclaim)` then `E(projects)` etc. |
| `WindowSizer` | Views.swift:449 | NSViewRepresentable that, only on a transition between onboarding and browser, sets content size (compact 520×400 non-resizable; full 1000×720 resizable) and centres the window. | `compact` bool | — |

### 1.2 Sidebar (NavigationSplitView sidebar column)

| Element | Where | What | State | Engine |
|---|---|---|---|---|
| `List(selection: $selectedProject)` `.listStyle(.sidebar)` | ContentView.swift:1087–1120 | Column width min 180 / ideal 200 / max 260. Three collapsible `Section(_, isExpanded:)`: **Running** (only if any live), **Favourites** (favourite && not live), **Projects** (rest; always present). A project appears in exactly one section. | `@AppStorage` `sidebar.running.expanded`, `sidebar.favourites.expanded`, `sidebar.projects.expanded` (all default true); `liveProjects: Set<String>` | selection change → `reload()` (ContentView.swift:450) |
| `ProjectRow` | Views.swift:474 | SF Symbol (project's `SYMBOL`, 12pt, 16 wide; white when selected, green when live, secondary otherwise) + name (13pt) + trailing small `ProgressView` spinner when live. No favourite star is drawn. | `project`, `isLive`, `isSelected` | — |
| Project context menu | ContentView.swift:1131 | "Add to Favourites"/"Remove from Favourites"; ─; "Project settings…"; "Reveal repository in Finder"; "Open config in a text editor"; ─; "Remove Project…" (destructive → sets `removing`). | — | favourite: `F(favourite <id> on|off)` then `E(projects)`; config path from `E(paths <id>)[2]` |
| Sidebar toggle | system (visible in screenshots, top of sidebar) | `SidebarCommands()` adds View ▸ Toggle Sidebar; NavigationSplitView supplies the titlebar button. | — | — |

### 1.3 Detail pane

| Element | Where | What | State | Engine |
|---|---|---|---|---|
| No project selected | ContentView.swift:250 | `ContentUnavailableView("No project selected", systemImage:"square.stack.3d.up", description: "Projects are declared in <projectsDir>")` | — | `E(projects-dir)` once |
| Loading | ContentView.swift:259 | Centred small `ProgressView`; title = project name, subtitle blank. Never shows previous project's data. | `current == nil` | — |
| Window title / subtitle | ContentView.swift:787–788 | `.navigationTitle(project name)`, `.navigationSubtitle("<ref> · <preset>")` when running, else empty. (Screenshot: "Northwind Web / feat/checkout-summary · web".) | snapshot | — |
| Empty branch list | ContentView.swift:695 | `ContentUnavailableView` — "No branches to show" (arrow.triangle.branch) + "Merged branches and anything older than a week are hidden. Change that in the filter menu." or "No match" (magnifyingglass) + "No branch matches “q”." | `filter` | — |
| Branch `List(rows, selection:$selection)` `.listStyle(.inset)` | ContentView.swift:708 | One `BranchRow` per visible branch (filtered by `visible()`, §4.2). | `selection: String?` (ref) | — |
| `RunStrip` (top safe-area inset, only when running) | ContentView.swift:723; Views.swift:56 | Glass bar (`.glassEffect(.regular, in: .rect(cornerRadius: 14))`): 8pt health dot with glow (colour by worst health) + label ("Healthy"/"Starting"/"Not Responding"/"Unknown") + badges: "started elsewhere" (orange, arrow.up.right.square) if adopted, else "in place" (orange, pencil) if inPlace; "N commit(s) behind" (blue, arrow.down.circle) if behind>0; "now on <branch>" (red, exclamationmark.triangle.fill) if switchedTo; uptime `HH:MM:SS` monospaced, ticking every 1 s via `TimelineView(.periodic(by:1))`; Spacer; one "localhost:<port>" label per target (tooltip = target name). Tooltips on each badge. | `RunState`, `HealthMonitor` (observed) | — |
| `BranchRow` | Views.swift:149 | Optional 16pt leading gutter (reserved whenever anything runs; spinner in it for the live row). Line 1: cloud glyph if remote; branch display name (middle-truncated); one of badge "default" (blue) / PR badge (open green arrow.triangle.pull, merged purple arrow.triangle.merge, closed red xmark) / "merged" (subsumed, purple); owner badge (grey, e.g. "me", "Priya"); "checked out" (orange, pencil) or "in another worktree" (purple, arrow.triangle.branch); "ready" (green, bolt.fill) if worktree exists and not live. Line 2: subject (PR title or tip commit subject), secondary. Trailing column: age ("7m", "1d") and divergence "↑3 ↓4" (tertiary, tooltip "Commits: 3 ahead of the default branch, 4 behind"). | `branch`, `isLive`, `showGutter`, `isSelected` | — |
| Branch context menu | ContentView.swift:714 | Only "Remove worktree" when `branch.ready && state.ref != branch.ref`. | — | `R(remove-worktree <p> <ref>)` |
| Bottom action bar | ContentView.swift:733–782 | Only when a branch is selected. Divider; HStack: preset segmented `Picker` (only if >1 preset; `.controlSize(.large)`; width = min(count,4)×72; labels `.capitalized`; disabled when the selected branch is the running one) · Spacer · `GlassEffectContainer` of buttons: **Logs** (glass, running only) → Logs sheet; **Open** (glass, running + has URL) → `NSWorkspace.open(first target URL)`; **Update** (glass, running && behind>0; tooltip "Re-check-out <ref> at its latest commit and restart"); **primary** (glassProminent, red tint if destructive, `.keyboardShortcut(.defaultAction)` = Return, tooltip "<title> <ref>"). | `primary()` (ContentView.swift:208) | Update: `R(update <p>)`. Primary — see below |
| Primary button logic | ContentView.swift:208 | Selected == running ref → **Stop** (red): adopted → `F(kill-port <pid>)` per alive target; else `R(stop <p>)`. Else if something running → **Switch**. Else **Run in Place** if `branch.isCurrent && !isRemote`, otherwise **Start**. Switch/Start go via `startChecking` (§4.4). | — | `E(check-ports <p> <preset>)` then `R(run <p> <ref> <preset> [offset] [--in-place])` |

### 1.4 Toolbar (window toolbar, `.primaryAction` group) — ContentView.swift:473–570

Visual: in the screenshot the three buttons share one glass capsule, with the search field in its own capsule to the right.

| Item | Where | Details | Engine |
|---|---|---|---|
| Search | ContentView.swift:473 | `.searchable(text:$filter.query, placement:.toolbar, prompt:"Search branches")` → NSSearchToolbarItem (collapses to a loupe pill when narrow). Matches `ref` or `subject`, case-insensitive; a query overrides every filter. | — |
| Filter menu | 477 | Glyph `line.3.horizontal.decrease`, tinted accent when any filter active; `.menuIndicator(.hidden)`; tooltip "Filter branches". Toggles: "Only my branches"; ─; "Show merged"; "Show older than a week"; "Show all remote branches". | — |
| Refresh | 492 | `arrow.clockwise`, tooltip "Re-read branches and pull request state", **⌘⇧R**. | `E(refresh <p>)`, clear cache, `reload()` |
| More (•••) menu | 504 | Glyph `ellipsis`. Contents, in order (conditional items in brackets): [if branch selected: "Copy branch name"; [running this branch: "Copy URL"]; [has PR: "Open pull request #N"]; ─; [branch.ready: submenu "Open worktree in" ▸ installed editors; "Reveal worktree in Finder"; "Remove worktree" (disabled if it is the running ref); ─]]; [branch.canRunInPlace: "Run in an isolated worktree instead…"; ─]; "Add project…"; ─; "Ports…"; "Disk…"; "Open logs in Finder"; [project: "Reveal repository in Finder"; ─; "Project settings…"; "Open config in a text editor"]; ─; Toggle "Check for updates on launch"; Picker submenu "Show Runbranch in" ▸ Dock Only / Dock and Menu Bar / Menu Bar Only. | PR URL = `https://github.com/<paths[4]>/pull/<N>`; worktree path = `E(paths <p> <ref>)[5]`; remove = `R(remove-worktree …)`; isolated = `startChecking(inPlace:false)` |

### 1.5 Hidden keyboard shortcuts — ContentView.swift:451–466

Zero-opacity buttons in `.background`: **⌘1…⌘9** select project 1–9 (in `projects` order, not sidebar order); **⌘.** stop selected (`R(stop <p>)`); **⌘,** open Project settings (duplicate of the menu command).

### 1.6 Menu bar commands — App.swift:365–401

| Menu | Item | Shortcut | Action |
|---|---|---|---|
| App (replaces `.appInfo`) | About Runbranch | — | `AboutPanel.shared.show()` |
| App | Check for Updates… | — | `Updater.checkNow()` then present Update sheet if none open |
| File (replaces `.newItem`, so no New Window) | Add a Project… | ⌘N | `NSOpenPanel` → `E(add <path>)` |
| File | Scan for Projects… | ⌘⇧N | Scan sheet |
| File (after newItem) | Project Settings… | ⌘, | Editor sheet; `.disabled(!hasSelection())` (evaluated at build time — may be stale) |
| File | Reveal Projects Folder in Finder | — | opens `Engine.projectsDir` |
| File | Refresh | ⌘R | `reload()` only (no `E(refresh)`; differs from toolbar ⌘⇧R) |
| View | Toggle Sidebar | ⌃⌘S (system) | `SidebarCommands()` |
| Help (replaces `.help`) | Runbranch on GitHub | — | open repo URL |
| (App menu, system) | Quit | ⌘Q | — |

`MenuBridge` (App.swift:229) is the closure bridge the view fills in (ContentView.swift:296–310).

### 1.7 Status item (menu bar extra) — `MenuBarController`, App.swift:61–222

- `NSStatusItem` (variable length), template image `MenuBarIcon` (@1x/@2x), fallback title "RB", tooltip "Runbranch". Installed only when presentation ≠ dock.
- `NSMenu` rebuilt on every open (`menuWillOpen` → `refresh()`):
  1. disabled heading: "<project> — <branch>" if running, "<project> — not running", or "No project selected" (reflects the **selected** project, not all runs);
  2. disabled health line if `healthLabel` set — **never assigned anywhere (dead code)**;
  3. ─; "Stop" (running only) → `onStop` → `R(stop <selected>)`;
  4. "Open Runbranch" → becomes `.regular`, activates, `openWindow(id:"main")`;
  5. ─; "Quit Runbranch" (⌘Q).
- On last window close in menuBar mode, reverts to `.accessory` (App.swift:209).

### 1.8 Sheets (single `enum Sheet`, ContentView.swift:76; only one at a time; `present()` 957 dismisses then presents next runloop turn)

| Sheet | File:line | Size | Shows | State | Engine |
|---|---|---|---|---|---|
| **Run** `.run(title)` | RunSheet.swift:19 | 620×420 | Header: spinner / red xmark.circle.fill / green checkmark.circle.fill + headline ("<title>", "— done", "— failed"). Monospaced 11pt selectable streamed lines, auto-scroll to bottom. Footer: "Copy log" (failed only), "Stop" (⎋, while running → `terminate()`), "Close" (Return, when finished). **Auto-closes 0.8 s after success.** On close: clear cache, `syncProjectList`, `reload`, `refreshLive`. | `Runner` | any `R(...)` |
| **Logs** `.logs` | RunSheet.swift:103 | 680×460 | Header: text.alignleft glyph, "Logs", subtitle = target name (only if one target); segmented target picker (>1 target, 160 wide); "Filter" text field (120); folder button (bordered, tooltip "Reveal in Finder") → selects `<logDir>/<target>.log`. Body: tail of the log, errors tinted red, always pinned to bottom. Footer: "N lines", "· N matching error" (red), "Done" (Return). | `selected`, `lines`, `offset`, `filter` | none — reads `<logDir>/<target>.log` directly (§4.6) |
| **Ports** `.ports` | Ports.swift:151 | 520×460 | Header: network glyph, "Ports", "Every port your projects declare, and what is on it". Rows: port (mono, 52 wide), "<project> · <target>", badge free / running (green bolt) / "<owner>, outside" or "in use" (orange triangle); second line pid+command when occupied. Optional overlap section: arrow.triangle.branch (orange) "One port is claimed by more than one project"; each overlap row: port, projects, "Move…" pull-down menu ▸ project names. Footer: "Done". Refreshed by the 30 s tick while open. | `portRows`, `portOverlaps` | `E(ports)`, `E(overlaps)`; Move: `E(suggest-offset <p>)` then `set <p> PORT_OFFSET <n>` |
| **Disk** `.disk` | Disk.swift:17 | 520×400 | Header: internaldrive glyph, "Disk", summary ("Measuring…", "Nothing on disk yet", "3 worktrees · 49 KB, 33 KB not in use", "…, all of it in use"). Body: spinner + "Adding up what the worktrees cost." / empty text / rows: ref (or slug if ref "?"), badge running / "branch gone" (orange trash) / idle, project, size. Footer: status text, "Reclaim…" menu ▸ prunable projects, "Done". | `diskRows: [DiskRow]?` (nil = measuring) | `E(disk)` on open (seconds); `F(prune-gone <p>)` |
| **Scan** `.scan` | ScanSheet.swift:22 | 560×480 | Header: folder.badge.plus, "Find projects", "Runbranch reads each repository and proposes a config you can correct." Phases: idle/scanning (folder TextField mono pre-filled `~/Development` or `RB_SCAN_ROOT`, "Choose…" NSOpenPanel, hint "Git repositories up to three levels deep, ignoring node_modules.", "Looking…" spinner) → results (list of Toggle rows name + abbreviated path; nothing preselected; or `ContentUnavailableView("Nothing new here", folder)`) → adding (determinate progress 260 wide, "Reading <name>…") → done ("Added N project(s)", auto-close after 650 ms). Footer: "Select all/none", "Cancel" (⎋), "Scan"/"Add N"/"Done". On close with added>0: select first new project. | `phase`, `found`, `chosen`, `progress` | `E(scan <dir>)`, `E(add <path>)` per chosen |
| **Project editor** `.editing(id)` | ProjectEditor.swift:23 | 560×620 | Header: project NAME + "N unsaved". `Form` `.formStyle(.grouped)`: **Project** — Name, Sidebar icon (`SymbolPicker`), Default branch, Repository (read-only, `~`-abbreviated mono). **Run** — Targets `TextEditor` (mono, min 64 high, caption "Targets — one per line: name:port:health:command"), Always started (prompt "e.g. api"), Presets ("web=web  both=web,admin"), Port offset ("0") + live note (§4.8), Toggle "Targets come from a Procfile" (PROCFILE), Toggle "The server opens a browser itself" (OPENS_ITSELF). **Setup** — Install ("pnpm install --frozen-lockfile"), Runtime picker (None/mise/fnm/asdf/nvm), "Copy into the worktree" (".env.local"). **Infrastructure** — Compose services ("postgres valkey"), Compose project, Migrate, Seed, "Database URL variables" ("DATABASE_URL"). Optional info section if IN_REPO: doc.badge.gearshape "This project also has a .runbranch in its repository. Values here override it." Error line (red, exclamationmark.triangle, first line of engine stderr). Footer: "Reveal config", "Cancel" (⎋), "Save"/"Saving…" (Return; disabled when nothing dirty). | `f`, `original`, `dirtyKeys` | `E(get <id>)`; `set <id> <KEY> <value>` per dirty key, stop at first failure; `E(paths)[2]` for reveal |
| **Port conflict** `.resolvingPorts(PendingRun)` | Ports.swift:24 | 460×300 | Header: orange exclamationmark.triangle 20pt, "Ports already in use", subtitle by ownership (4 variants, Ports.swift:125). Rows: target, "port N", description ("<owner> — a Runbranch run" / "— started outside Runbranch" / "another app (pid N)"). Caveat paragraph when any clash is `env`-movable. Footer: "Cancel"; "Run on <firstPort+offset>" (glass); "Stop and Switch" (red prominent, Return) if any `ours` owners, else "Take Over Port(s)" (red prominent, **not** default) if outsiders. | `PendingRun` | Switch: `F(stop <owner>)` each, then `R(run…)`; Take over: `F(kill-port <pid>)` each outside clash, then `R(run…)`; Shift: `R(run <p> <ref> <preset> <offset> [--in-place])` |
| **Update** `.update` | Updates.swift:663 | 520×440 (release) / 520×260 (status) | Header: Mark 34pt + title ("Runbranch X is available" / "Could not check for updates" / "This is a development build" / "Runbranch is up to date") + subtitle. Body: rendered notes (`NotesText`) or status glyph (wifi.exclamationmark / hammer / checkmark.circle) + line. Footer by phase: progress bar (determinate or indeterminate) + label; failed → reason + "Open Releases" + "Close"; release → plain "Turn Off Update Checks" (left), "Later", "Update" (Return); else "Done". | `Updater` | GitHub API, not engine |
| **What's new** `.whatsNew(entries)` | Updates.swift:809 | 520×440 | Header: Mark + "What's new in Runbranch X" + "N releases since you last opened it" / "Updated from within Runbranch". Body: per entry (version subheading if >1) `NotesText`. Footer: link "Full changelog", "Continue". | entries | bundled `ReleaseNotes.json` |

### 1.9 Popover

`SymbolPicker` (Views.swift:268): bordered button showing current glyph + chevron.down; `.popover(arrowEdge:.bottom)` 330 wide: capsule search field (magnifyingglass) → `LazyVGrid` 8 columns × 34pt cells, 240 high, selected cell tinted accent 25%, tooltip = symbol name; "Nothing matches “q”". Filter is substring over the SF Symbol name.

### 1.10 Alerts and dialogs

| Dialog | Where | Content | Action |
|---|---|---|---|
| Remove project `confirmationDialog` | ContentView.swift:643 | Title "Remove <name>?" ; message "Deletes this project's config file and any worktrees, logs and ports Runbranch created for it. / The repository at <~repo> is not touched." | "Remove Project" (destructive) → `R(remove <id>)`; "Cancel" |
| Engine problem `alert` | ContentView.swift:679 | "Runbranch could not do that" + the engine's verbatim stderr. | "OK" |
| Add failed `NSAlert` | ContentView.swift:1216 | "Could not add that folder" / "It needs to be a git repository, and not already declared." | OK |
| Add project `NSOpenPanel` | ContentView.swift:1204 | directories only, prompt "Add", message "Choose a git repository", starts in `~/Development`. On success opens the new `.conf` in the default app. | `E(add)` |
| Scan "Choose…" `NSOpenPanel` | ScanSheet.swift:148 | directory chooser | — |

### 1.11 About and onboarding

- **About** (`AboutPanel`, App.swift:243; `AboutView` 282): standalone `NSPanel` 340 wide, titled/closable/fullSizeContentView, hidden transparent title bar, movable by background, not floating. App icon 128pt, "Runbranch" 22pt semibold, "Version X", orange "development build" badge (hammer.fill) on dev builds, "Created by Alec McLeod", "GPL-3.0 — free to use, change and share alike", link "Runbranch on GitHub". Note: `docs/img/about.png` actually shows only the main window (the panel did not make it into the capture) — it is not a usable reference.
- **Welcome / onboarding** (`WelcomeView`, Views.swift:395): shown when there are no projects. Window forced to 520×400 non-resizable, toolbar hidden. Mark.png 84pt, "Runbranch" 24pt semibold, "Run any branch of any project, on a real port.", "Isolated in a throwaway worktree, or in place in your checkout.", buttons "Scan…" (glassProminent) and "Add a project…" (glass), both 124 wide, large; footer "Projects are plain config files you can commit to the repository."
- **Settings**: there is no Settings scene. App-level preferences (update check, presentation) live in the ••• menu; per-project settings are the editor sheet.

---

## 2. Tahoe / macOS 26 / AppKit-specific APIs used

| API | Where | Notes |
|---|---|---|
| Liquid Glass: `.glassEffect(.regular, in: .rect(cornerRadius:14))` | Views.swift:142 (RunStrip) | macOS 26 only |
| `GlassEffectContainer(spacing:10)` | ContentView.swift:752 | merges bottom buttons' glass |
| `.buttonStyle(.glass)` / `.glassProminent` | every sheet footer, bottom bar, Welcome | macOS 26 |
| `.toolbarBackgroundVisibility(.automatic, for: .windowToolbar)` | ContentView.swift:273 | scroll-edge toolbar material |
| Grouped toolbar capsule (automatic from `ToolbarItemGroup`) | ContentView.swift:476 | Tahoe renders the group as one glass pill |
| `.searchable(placement:.toolbar)` → NSSearchToolbarItem | ContentView.swift:473 | collapsible search pill |
| `NavigationSplitView`, `.listStyle(.sidebar)`, `.navigationSplitViewColumnWidth`, `Section(isExpanded:)` | ContentView.swift:246, 1099 | translucent sidebar, collapsible headers |
| `.navigationTitle` + `.navigationSubtitle` | ContentView.swift:787 | two-line title in toolbar |
| `ContentUnavailableView` | ContentView.swift:250, 697; ScanSheet.swift:75 | |
| `.listStyle(.inset)`, List selection tint, `.contextMenu` | ContentView.swift:708 | |
| `Menu` with `.menuIndicator(.hidden)`, `.menuStyle(.button)` pull-downs | ContentView.swift:477, 504; Ports.swift:258; Disk.swift:127 | |
| `Picker(.segmented)` with `.controlSize(.large)` | ContentView.swift:740; RunSheet.swift:191 | |
| `ProgressView` — small circular spinner (`.controlSize(.small)`), linear determinate, linear indeterminate | Views.swift:161, 488; ScanSheet.swift:103; Updates.swift:798–800 | |
| `TimelineView(.periodic(from:by:1))` | Views.swift:123 | uptime tick |
| `Form` `.formStyle(.grouped)`, `LabeledContent`, `TextEditor`, `Toggle` (switch style in forms) | ProjectEditor.swift:91 | System-Settings look |
| `.popover(arrowEdge:)`, `LazyVGrid` | Views.swift:330 | |
| `.textSelection(.enabled)`, `.monospacedDigit()`, `.font(design:.monospaced)` | logs, strip | |
| `Text(AttributedString(markdown:, .inlineOnlyPreservingWhitespace))` | Updates.swift:651 | inline bold/code |
| `Link` | App.swift:321; Updates.swift:851 | |
| `.help()` tooltips | 17 places | |
| `.keyboardShortcut(.defaultAction / .cancelAction / "n" / ...)` | throughout | Return/⎋ |
| `@AppStorage` / UserDefaults | ContentView.swift:144–150; App.swift:51 | |
| `.confirmationDialog`, `.alert`, `.sheet(item:)` | ContentView.swift:571, 643, 679 | |
| SF Symbols (`Image(systemName:)`), incl. config-driven `SYMBOL` | everywhere; Model.swift:137 | ~30 fixed + 137 in picker |
| `Color(nsColor:.systemBlue)`, `.accentColor`, `.secondary/.tertiary` hierarchical styles | Views.swift:23 | |
| **AppKit**: `NSStatusItem`/`NSStatusBar`/`NSMenu`/`NSMenuDelegate`, template `NSImage` | App.swift:119–222 | |
| `NSApp.setActivationPolicy(.regular/.accessory)`, `NSApp.activate`, `NSApp.occlusionState` | App.swift:101; ContentView.swift:667 | |
| `NSPanel` + `NSHostingView` (About) | App.swift:253 | |
| `NSOpenPanel`, `NSAlert` | ContentView.swift:1204, 1216; ScanSheet.swift:149 | |
| `NSWorkspace.open(url)`, `.selectFile(_:inFileViewerRootedAtPath:)` (Reveal in Finder), `.urlForApplication(withBundleIdentifier:)`, `.open(_:withApplicationAt:configuration:)` | many; Engine.swift:467–488 | |
| `NSPasteboard.general` | ContentView.swift:507; RunSheet.swift:65 | |
| `NSAppleScript` (Terminal "do script … && claude") | Engine.swift:472 | Claude Code launcher |
| `NSWindow.willCloseNotification`, `allowsAutomaticWindowTabbing`, `styleMask` changes | App.swift:92, 356; Views.swift:466 | |
| `NSViewRepresentable` (WindowSizer) | Views.swift:449 | |
| `Process`/`Pipe`, `/bin/zsh -lic "env -0"` | Engine.swift | |
| `URLSession` (health, GitHub), `CryptoKit.SHA256`, `hdiutil`, `/bin/bash install-update.sh` | Engine.swift:391; Updates.swift | |
| ScreenCaptureKit + Vision OCR (screenshots / self-test only) | Screenshot.swift | test tooling, not UI |

---

## 3. Mac → WinUI 3 mapping

### 3.1 Components

| Mac | WinUI 3 / Windows App SDK | Confidence / loss |
|---|---|---|
| `Window` single scene | One `Microsoft.UI.Xaml.Window`; single-instance via `AppInstance.FindOrRegisterForKey` + `RedirectActivationToAsync` | High |
| Transparent titlebar + toolbar | `ExtendsContentIntoTitleBar = true` + WinUI `TitleBar` control (WinAppSDK 1.7+) with title/subtitle, back/pane-toggle button, and content slot | Medium — Mac merges title and toolbar into one strip; `TitleBar` can host the search box and buttons, but caption buttons sit top-right |
| Liquid Glass window / sidebar translucency | `MicaBackdrop` (Kind=Base) on window; sidebar pane transparent over Mica | Medium — Mica is wallpaper-tinted, not refractive glass |
| `.glassEffect` RunStrip | `Border` with `CardBackgroundFillColorDefaultBrush` + `CardStrokeColorDefaultBrush`, CornerRadius 8 (Fluent uses 4/8, not 14); or `DesktopAcrylicBackdrop`-style `AcrylicBrush` | Lossy — no live glass; Card is the Windows idiom |
| `.glass` buttons | `Button` (default style) | High |
| `.glassProminent` | `Button Style="{StaticResource AccentButtonStyle}"` | High |
| red-tinted destructive prominent (Stop, Stop and Switch, Take Over) | Custom style: AccentButtonStyle with `SystemFillColorCriticalBrush` background | Medium — Windows has no stock destructive button; red accent is custom |
| `GlassEffectContainer` | `StackPanel Orientation=Horizontal Spacing=8` | High (no merge effect) |
| `NavigationSplitView` | `NavigationView PaneDisplayMode=Left`, `IsSettingsVisible=False`, `IsBackButtonVisible=Collapsed`, OpenPaneLength≈220; or `SplitView` + `ListView` | Medium — see decision D3 |
| Sidebar collapsible `Section`s | `NavigationViewItem` parent (SelectsOnInvoked=False) with `MenuItems` children, or `NavigationViewItemHeader` (not collapsible). Custom: grouped `ListView` with `Expander` headers | Medium — NavigationView headers do not collapse natively |
| `ProjectRow` spinner | `ProgressRing IsActive=True Width=16 Height=16` | High |
| Branch `List(.inset)` + selection | `ListView SelectionMode=Single` with `ItemTemplate`; or `ItemsView` | High |
| `.contextMenu` | `ContextFlyout` = `MenuFlyout` (`MenuFlyoutItem`, `MenuFlyoutSeparator`, `MenuFlyoutSubItem`, `ToggleMenuFlyoutItem`, `RadioMenuFlyoutItem`) | High |
| Toolbar filter / refresh / ••• capsule | `CommandBar` (`AppBarButton`, overflow) or three `Button`s with `SubtleButtonStyle` inside the TitleBar; filter & more as `DropDownButton`/`Button.Flyout = MenuFlyout` | High |
| Filter glyph accent when active | Bind `Foreground` to `AccentTextFillColorPrimaryBrush` | High |
| `.searchable` toolbar | `AutoSuggestBox QueryIcon=Find PlaceholderText="Search branches"` in `TitleBar.Content` | Medium — does not auto-collapse to an icon; can hide below a width breakpoint via VisualStateManager |
| `.navigationTitle/.navigationSubtitle` | `TitleBar.Title` / `TitleBar.Subtitle` | High (both properties exist) |
| `ContentUnavailableView` | Custom `StackPanel`: `FontIcon` 48 + `TextBlock` (SubtitleTextBlockStyle) + body text | High (no stock control) |
| `Picker(.segmented)` presets / log targets | `SelectorBar` (WinAppSDK 1.5+) or `RadioButtons`; closest look: toggle `SegmentedControl` from CommunityToolkit (`CommunityToolkit.WinUI.Controls.Segmented`) | Medium — Segmented from Toolkit is the true match |
| `Badge` capsules | Custom `Border CornerRadius=10 Padding=6,2` + `FontIcon` 8pt + `TextBlock` 10pt, background = colour @14% | High (custom). `InfoBadge` is for counts/dots only — not a fit except the health dot |
| Health dot with glow | `Ellipse 8×8` (+ `ThemeShadow` or `DropShadow` via Composition) | Medium — glow is a Composition effect |
| `TimelineView` 1 s | `DispatcherQueueTimer` (Interval 1 s) updating only the uptime `TextBlock` | High |
| `.help` tooltips | `ToolTipService.ToolTip` | High |
| `.sheet(item:)` | `ContentDialog` (one at a time per XamlRoot — matches the single `Sheet` enum) | Medium — default MaxWidth 548; override `ContentDialogMaxWidth`/`MaxHeight` resources for 620–680 wide sheets; custom header layout goes in `Content`, footer uses Primary/Secondary/Close buttons or custom |
| Run sheet streaming log | `ContentDialog` with `ScrollViewer` + `ItemsRepeater` of `TextBlock` (Cascadia Mono 11, `IsTextSelectionEnabled`) ; Stop = CloseButton | Medium — ContentDialog blocks Esc/Enter semantics differently; auto-close via `dialog.Hide()` |
| Log viewer | Same, or a secondary `Window` | Medium — see D2 |
| `Form(.grouped)` editor | `ScrollViewer` + `StackPanel` of `CommunityToolkit.WinUI.Controls.SettingsCard` inside `SettingsExpander`/section headers — the Windows Settings look | High (Toolkit) — this is the direct analogue of grouped Form |
| `TextField` | `TextBox` (PlaceholderText = prompt) | High |
| `TextEditor` targets | `TextBox AcceptsReturn=True TextWrapping=NoWrap FontFamily=Cascadia Mono` | High |
| `Toggle` in form | `ToggleSwitch` | High |
| Runtime `Picker` | `ComboBox` | High |
| `SymbolPicker` popover | `DropDownButton` with `Flyout` containing `AutoSuggestBox`/`TextBox` + `GridView` of `FontIcon` (8 columns, 34 px) | High |
| `.confirmationDialog` destructive | `ContentDialog` with PrimaryButtonText="Remove Project", `DefaultButton=Close` | High |
| `.alert` | `ContentDialog` (Close "OK") or `InfoBar` Severity=Error at top of detail pane | Medium — see D8 |
| `NSOpenPanel` directories | `Windows.Storage.Pickers.FolderPicker` (needs `InitializeWithWindow`) or WinAppSDK 1.8 `Microsoft.Windows.Storage.Pickers.FolderPicker` | High |
| `NSAlert` | `ContentDialog` | High |
| `ProgressView` small spinner | `ProgressRing` | High |
| linear determinate / indeterminate | `ProgressBar` (Value / `IsIndeterminate=True`) | High |
| `Link` | `HyperlinkButton` | High |
| `Menu` pull-down "Move…", "Reclaim…" | `DropDownButton` + `MenuFlyout` | High |
| `NotesText` mini-markdown | Custom `RichTextBlock` builder (Paragraph/Bold/Run with Cascadia for code), or CommunityToolkit `MarkdownTextBlock` (Labs) | Medium |
| `NSStatusItem` + `NSMenu` | `H.NotifyIcon.WinUI` `TaskbarIcon` with `ContextFlyout` (MenuFlyout) and ToolTipText; icon = .ico, light/dark variants | Medium — tray icons are not auto-tinted like template images; ship two icons and swap on theme |
| Activation policy .accessory (no Dock icon) | Hide window (`AppWindow.Hide()`), `AppWindow.IsShownInSwitchers=false`; app keeps running via tray | Medium |
| `applicationShouldTerminateAfterLastWindowClosed` | Handle `AppWindow.Closing`: cancel + hide when tray mode, else exit | High |
| About `NSPanel` | `ContentDialog` or small secondary `Window` with `OverlappedPresenter` (no maximise/minimise, not resizable) | Medium |
| `WindowSizer` | `AppWindow.Resize(new SizeInt32(...))` (DPI-scaled), `OverlappedPresenter.IsResizable`, centre via `DisplayArea` | High |
| Min window size | `OverlappedPresenter.PreferredMinimumWidth/Height` (WinAppSDK 1.7+) | High |
| `NSWorkspace.open(url)` | `Windows.System.Launcher.LaunchUriAsync` | High |
| Reveal in Finder (`selectFile`) | `explorer.exe /select,"<path>"` (file) or `Launcher.LaunchFolderPathAsync` (folder) | High |
| `NSPasteboard` | `Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(DataPackage)` | High |
| `@AppStorage`/UserDefaults | `ApplicationData.Current.LocalSettings` (packaged) or a JSON file in `%LOCALAPPDATA%\Runbranch` (unpackaged) | High |
| `NSApp.occlusionState.visible` | `AppWindow.IsVisible` && presenter State != Minimized (no true occlusion API) | Medium |
| `NSAppleScript` Terminal | `wt.exe -d "<path>" claude` / `wt.exe -d "<path>"` | High |
| `Process`/`Pipe` | `System.Diagnostics.Process` with `RedirectStandardOutput/Error`, `OutputDataReceived` | High |
| `/bin/zsh -lic env -0` login env | Not needed on Windows (GUI apps inherit user PATH); if the engine runs under Git Bash use `bash -lc` once with a 5 s deadline | depends on D1 |
| `URLSession` / `CryptoKit` | `HttpClient` / `System.Security.Cryptography.SHA256` | High |
| Keyboard shortcuts | `KeyboardAccelerator` on buttons/menu items; global ones on the root element | High |
| Default/cancel action (Return/⎋) | `ContentDialog.DefaultButton`; outside dialogs, `KeyboardAccelerator Key=Enter` on the primary button | Medium |
| `SidebarCommands` toggle | `NavigationView` pane toggle button / `TitleBar.IsPaneToggleButtonVisible` | High |
| Accent-coloured sidebar selection with white icon | NavigationView selection indicator (pill + subtle fill) | Lossy — Windows selection is a subtle fill with an accent pill, not a solid accent fill; the `onFill` badge logic becomes unnecessary |

### 3.2 SF Symbol → Segoe Fluent Icons

Font: `Segoe Fluent Icons` (Win 11 built-in; `SymbolThemeFontFamily`). Codepoints below are from the Segoe MDL2/Fluent shared set; the ones marked **(verify)** I am not certain of and should be checked against Microsoft's "Segoe Fluent Icons font" reference page before use. "—" means no reasonable Segoe glyph: use **Fluent UI System Icons** (`FluentIcons.WinUI` NuGet / `FluentSystemIcons-Regular.ttf`), which has git-specific and object glyphs (named in the Fallback column).

**Fixed UI symbols**

| SF Symbol | Used for | Segoe Fluent Icons | Fallback (Fluent UI System Icons) |
|---|---|---|---|
| line.3.horizontal.decrease | filter menu | E71C Filter | Filter |
| arrow.clockwise | refresh | E72C Refresh | ArrowClockwise |
| ellipsis | more | E712 More | MoreHorizontal |
| magnifyingglass | search / no match | E721 Search | Search |
| square.stack.3d.up | no project selected | E8F1 Library (verify) | Stack / BoxMultiple |
| arrow.triangle.branch | empty list, "in another worktree", overlap header | — | BranchFork |
| arrow.triangle.pull | PR open | — | BranchRequest |
| arrow.triangle.merge | PR merged / subsumed | — | Merge (verify name) |
| xmark | PR closed | E711 Cancel | Dismiss |
| shippingbox | default project glyph | E7B8 Package | Box |
| arrow.up.right.square | started elsewhere | E8A7 OpenInNewWindow | Open |
| pencil | in place / checked out | E70F Edit | Edit |
| arrow.down.circle | commits behind | E896 Download (verify look) | ArrowCircleDown |
| exclamationmark.triangle(.fill) | warnings | E7BA Warning | Warning |
| cloud | remote branch | E753 Cloud | Cloud |
| bolt.fill | ready / running | E945 LightningBolt | Flash |
| chevron.down | picker affordance | E70D ChevronDown | ChevronDown |
| xmark.circle.fill | run failed | EB90 StatusErrorFull (verify) / EA39 ErrorBadge | DismissCircle |
| checkmark.circle.fill | run succeeded | EC61 CompletedSolid (verify) / E930 Completed | CheckmarkCircle |
| checkmark.circle | up to date | E930 Completed | CheckmarkCircle |
| text.alignleft | logs header | E8E4 AlignLeft | TextAlignLeft |
| folder | reveal log, scan empty | E8B7 Folder | Folder |
| folder.badge.plus | scan header | E8F4 NewFolder | FolderAdd |
| doc.badge.gearshape | in-repo config note | E8A5 Document (no badge) | DocumentSettings |
| network | ports header | E968 Network (verify) / E774 Globe | Globe |
| internaldrive | disk header | EDA2 HardDrive | HardDrive |
| trash | branch gone | E74D Delete | Delete |
| wifi.exclamationmark | update check failed | EB5E WifiWarning? (verify) / E701 Wifi | WifiWarning |
| hammer / hammer.fill | dev build | E90F Repair | WrenchScrewdriver |

**SYMBOL choices in the project editor picker (Views.swift:273–309, 137 names)**

| SF Symbol | Segoe Fluent Icons | Fluent UI System fallback |
|---|---|---|
| shippingbox | E7B8 Package | Box |
| cube | — | Cube |
| cube.transparent | — | CubeTree / Cube |
| square.stack.3d.up | E8F1 Library (verify) | Stack |
| square.stack | E8F1 Library | Stack |
| folder | E8B7 Folder | Folder |
| folder.badge.gearshape | E8B7 Folder | FolderGear (verify) |
| tray.full | E719? no — use E7B8 | Tray (verify) / Archive |
| archivebox | E7B8 Package | Archive |
| briefcase | E821 Work (verify) | Briefcase |
| globe | E774 Globe | Globe |
| globe.americas | E909 World | Earth |
| network | E968 Network (verify) | Globe / DataUsage |
| antenna.radiowaves.left.and.right | EC05 NetworkTower (verify) | Broadcast |
| wifi | E701 Wifi | Wifi1 |
| link | E71B Link | Link |
| cloud | E753 Cloud | Cloud |
| icloud | E753 Cloud | Cloud |
| point.3.connected.trianglepath.dotted | — | Organization / Diagram |
| server.rack | — | Server |
| externaldrive | EDA2 HardDrive | HardDrive |
| internaldrive | EDA2 HardDrive | HardDrive |
| cylinder.split.1x2 | — | Database |
| chart.bar.doc.horizontal | E9D2 AreaChart? (verify) | DocumentBulletList / ChartMultiple |
| tablecells | E80A ViewAll (verify) | Table |
| list.bullet.rectangle | E8FD BulletedList | TextBulletListSquare |
| building.2 | E80F Home (poor) | BuildingMultiple |
| building.columns | — | BuildingBank |
| storefront | E719 Shop | BuildingShop |
| cart | E7BF ShoppingCart | Cart |
| creditcard | E8C7 PaymentCard | Payment |
| banknote | — | Money |
| chart.line.uptrend.xyaxis | E9D9 Diagnostic? (verify) | ArrowTrendingLines |
| chart.pie | EB05 PieSingle | DataPie |
| percent | — | Percent? / use TextBlock "%" |
| paintpalette | E790 Color | Color |
| paintbrush | E771 Personalize | PaintBrush |
| swatchpalette | E790 Color | ColorBackground |
| eyedropper | EF3C Eyedropper (verify) | Eyedropper |
| ruler | ED5E Ruler | Ruler |
| square.on.circle | — | Shapes |
| circle.hexagongrid | — | Grid / HexagonThree (verify) |
| wand.and.stars | — | Wand |
| sparkles | — | Sparkle |
| terminal | E756 CommandPrompt | WindowConsole |
| curlybraces | E943 Code | Braces |
| chevron.left.forwardslash.chevron.right | E943 Code | Code |
| hammer | E90F Repair | Wrench |
| wrench.and.screwdriver | E90F Repair | WrenchScrewdriver |
| gearshape.2 | E713 Setting | Settings |
| cpu | EEA1 (verify) | DeveloperBoard |
| memorychip | — | DeveloperBoard |
| ladybug | EBE8 Bug | Bug |
| testtube.2 | — | Beaker |
| flask | — | Beaker |
| doc.text | E8A5 Document | DocumentText |
| doc.richtext | E8A5 Document | DocumentImage |
| book | E82D Dictionary | Book |
| books.vertical | E8F1 Library | Library |
| text.book.closed | E82D Dictionary | BookOpen |
| newspaper | E789 ?/ (verify) | News |
| pencil.and.outline | E70F Edit | EditSettings / Edit |
| signature | EE56 InkingTool? (verify) | Signature |
| envelope | E715 Mail | Mail |
| bubble.left.and.bubble.right | E8F2 ChatBubbles | ChatMultiple |
| megaphone | E789 Megaphone (verify) | Megaphone |
| bell | EA8F Ringer | Alert |
| phone | E717 Phone | Call |
| video | E714 Video | Video |
| person.2 | E716 People | People |
| person.3 | E716 People | PeopleTeam |
| photo | E91B Photo | Image |
| photo.stack | E8B9 Picture | ImageMultiple |
| film | E8B2 Movies | FilmstripPlay |
| music.note | E8D6 Audio | MusicNote1 |
| waveform | — | Waveform? / use E8D6 |
| mic | E720 Microphone | Mic |
| play.rectangle | E768 Play | VideoClip |
| camera | E722 Camera | Camera |
| map | E826 Map (verify) | Map |
| location | E81D Location | Location |
| signpost.right | — | Directions |
| airplane | E709 Airplane | Airplane |
| car | E804 Car | VehicleCar |
| tram | E7C0 Bus / EB4D Train (verify) | VehicleSubway |
| leaf | — | Leaf |
| tree | — | Tree? / Leaf |
| flame | — | Fire |
| drop | EB42 Drop (verify) | Drop |
| bolt | E945 LightningBolt | Flash |
| sun.max | E706 Brightness | WeatherSunny |
| moon.stars | E708 QuietHours | WeatherMoon |
| star | E734 FavoriteStar | Star |
| heart | EB51 Heart | Heart |
| flag | E7C1 Flag | Flag |
| tag | E8EC Tag | Tag |
| bookmark | E8A4 Bookmarks | Bookmark |
| pin | E718 Pin | Pin |
| key | E8D7 Permissions | Key |
| lock | E72E Lock | LockClosed |
| shield | EA18 Shield | Shield |
| checkmark.seal | EB95 Certificate (verify) | CertificateBadge? / Ribbon |
| target | — | Target |
| scope | — | Target |
| puzzlepiece | EA86 Puzzle | PuzzlePiece |
| gamecontroller | E7FC Game | Games |
| dice | — | Dice? / use Games |
| crown | — | Crown? (verify) |
| gift | ECA3? (verify) | Gift |
| cup.and.saucer | EC32 Cafe | DrinkCoffee |
| fork.knife | ED56? (verify) | Food |

Recommendation: use **Fluent UI System Icons** as the primary glyph set (it covers every SF name above with a recognisable shape, including git branch/PR/merge, which Segoe Fluent lacks) and Segoe Fluent Icons only for chrome (Filter, Refresh, More, Search, Folder). Keep a single `Dictionary<string sfName, string glyph>` with an unknown-name fallback to the Box/Package glyph, mirroring Model.swift:144's `shippingbox` default.

---

## 4. Logic beyond presentation (must be replicated in C#)

### 4.1 Engine wire formats (Model.swift, Engine.swift)

All TSV, one record per line, empty lines skipped. Optional trailing fields must parse when absent (older engines).

- `projects` → `id name repo ? symbol favourite` — f[0] id (.conf basename), f[1] name, f[2] repo, f[4] SYMBOL (default "shippingbox" if missing/empty), f[5]=="1" favourite. Needs ≥3 fields. (f[3] unused.) Model.swift:140.
- `branches <p>` → ≥9 fields: ref, age (display string), timestamp (unix int), owner, mine ("1"), pr (OPEN/MERGED/CLOSED/else none), ready ("1"), isDefault, isCurrent; optional f[9] prNumber, f[10] subject, f[11] isRemote, f[12] checkedOutAt, f[13] ahead (int? — **absent ≠ 0**), f[14] behind (int?). Derived: `isSubsumed = !isDefault && ahead == 0` (only when ahead is known and zero); `hasDivergence = ahead>0 || behind>0`; `canRunInPlace = isCurrent && !isRemote`; `display` strips a leading `origin/` for remote. Model.swift:66.
- `presets <p>` → one name per line.
- `paths <p> [ref]` → first line TSV: [0] worktrees dir, [1] logs dir, [2] config file, [3] repo, [4] GitHub slug (owner/repo, may be empty), [5] the ref's worktree (only when ref passed). Indices used: 1, 2, 4, 5.
- `projects-dir` → one path; fallback `~/.runbranch/projects`. Read once.
- `state <p>` → lines by tag: `run ref preset started epoch worktree [inPlace] [adopted]` (≥6); `behind N`; `switched <branch>`; `target name port health pid alive` (≥6); or `idle`. `running = a run line exists`. Model.swift:191.
- `check-ports <p> <preset>` → exit ≠ 0 means conflict; lines `OFFSET N` and clashes `target port owner kind(ours|outside|unknown) pid move(explicit|env)` (≥6, port & pid ints). Derived: `owners` = unique owners with kind ours (non-empty, order kept); `outsiders` = same for outside; `strangers` = unknown; `canShift = any clash`; `shiftIsBestEffort = any move == env`; offset default 1. Model.swift:249–318.
- `ports` → `project target port state(free|ours|outside) owner ? pid what` (≥8; f[5] unused). Model.swift:381.
- `overlaps` → `port <space-separated projects>`; keep only lines with >1 project.
- `disk` → `project slug ref kb state(running|gone|idle)`; size formatted as file-style bytes from kb×1024, zero must render "0 KB" not "Zero KB".
- `suggest-offset <p>` → int on exit 0, else null; 0 means "nothing needs moving".
- `scan <dir>` → `name path`.
- `add <repo>` → exit 0 + first line `name file`, else failure.
- `get <p>` → `KEY<TAB>value` (value may itself contain tabs — rejoin); `\u0001` in values = newline (TARGETS). Keys used by the editor: NAME, SYMBOL, DEFAULT_BRANCH, REPO, TARGETS, ALWAYS, PRESETS, PORT_OFFSET, PROCFILE, OPENS_ITSELF, INSTALL, RUNTIME, COPY_FILES, COMPOSE_SERVICES, COMPOSE_PROJECT, MIGRATE, SEED, DB_URL_VARS, IN_REPO.
- `set <p> <KEY> <value>` → newlines encoded as `\u0001`; stderr on failure.
- `failure()` semantics (Engine.swift:237): capture stderr, strip literal "FAILED", trim; empty → "<cmd> failed, with nothing to say why."
- Streamed commands (`run`, `stop`, `update`, `remove`, `remove-worktree`): stdout+stderr merged, ANSI `\x1B\[[0-9;]*m` stripped, split on `\n`, empties dropped; `failed = exit != 0`. stdin always null.
- `hasCommand(name)`: PATH lookup, cached (used for `claude`).
- `abbreviatingHome`: replace home dir with `~` everywhere a path is shown (privacy in screenshots). On Windows: `%USERPROFILE%` → `~`.

### 4.2 Branch visibility filter (ContentView.swift:166)

For each branch, in order: non-empty query → show iff `ref` or `subject` contains query (lowercased, trimmed) — overrides everything. Else always show `isDefault` or the running ref. Else hide if `mineOnly && !mine`; hide if `isRemote && !showAllRemote && pr != open`; hide if `!showMerged && (pr == merged || isSubsumed)`; hide if `!showOlder && now - timestamp > 7 days`. Filter "active" (accent tint) = any of the four toggles on (query excluded). Filters are not persisted.

### 4.3 Snapshot, cache and selection (ContentView.swift:25, 998–1075)

- `ProjectSnapshot {id, branches, presets, state, paths}` loaded as one unit (`branches`, `presets`, `state`, `paths` calls) and swapped whole; the detail pane renders only if `snapshot.id == selectedProject`.
- `reload()`: show `cache[p]` immediately if present, then load fresh off-thread; drop the result if selection changed meanwhile; store in cache; `applySelection`.
- `applySelection`: start/stop health monitor for the run's targets; feed status item (project name, branch, running); preset = first preset if current not in list; if running → select running ref and its preset; else keep selection if still present, otherwise first branch with `mine && pr != merged`, else the default branch.
- Launch (`.task`, 274): `reclaim` (before anything is drawn) → `projects` → select first (or a running one in unattended modes) → `refreshLive` → `reload` → warm cache for every other project sequentially in background. Then wire status item & menu bridge; `showWhatsNew()`; `checkOnLaunch()`.
- `syncProjectList()` after every streamed op: re-read projects; if selected id vanished, clear it and select first.
- Cache invalidated: after run sheet closes, after editor save, after Refresh, after separate/update.
- After Add: select `added.name`, open the .conf in the default app. After Scan: select the first project not present before.

### 4.4 Start flow with port check (ContentView.swift:796–961)

`startChecking(p, ref, preset, title, inPlace)`: `check-ports p preset`; if exit ≠ 0 and parse yields clashes → Port conflict sheet; else stream `run p ref preset [--in-place]`. Resolutions: Switch = `stop` each `owners` (abort with alert on first failure) → `syncProjectList` → run. Take over = `kill-port <pid>` for each `outside` clash (abort on failure) → run. Shift = run with `freeOffset` positional arg (button label shows first clash port + offset). Stop of an adopted run = `kill-port` each alive target pid, then sync/reload/refreshLive. `present()` must dismiss-then-present on the next dispatcher tick when swapping sheets (ContentDialog has the same one-at-a-time limit — `ShowAsync` throws if another is open).

### 4.5 Health monitor (Engine.swift:361–428)

- `watch(targets)`: cancel timer; empty → clear. Seed unseen targets as `unknown`; poll immediately, then every **5 s**.
- Per target: if `!alive` or no URL → `failing`. Else GET `http://localhost:<port><health or "/">`, timeout **3 s**. HTTP response with status < 500 → `healthy`; ≥ 500 → `failing`. No HTTP response (error/timeout) → `failing` if it was `healthy`, otherwise `starting`.
- Worst-of for the strip (Views.swift:70): any failing → failing; any starting or no statuses → starting; all healthy → healthy; else starting. Labels: healthy/starting/"not responding"/unknown (capitalised in UI); colours green/orange/red/secondary.
- `stop()` clears everything.

### 4.6 Log tailing (RunSheet.swift:103–378)

- File `<logDir>/<target>.log`; initial selected target = first target (set at construction, not on appear).
- Loop: wait 200 ms after presentation, then `load()` every **1.5 s** until dismissed; restarts (reset) when target changes; re-picks target if the targets list changes and the selection is invalid.
- `load()`: size < consumed offset → reset (log truncated on restart). On first read of a file > **256 KiB**, start at size−256 KiB and drop the first (partial) line. Read to EOF, commit only up to the last `\n` (keep remainder for next tick), advance offset by committed bytes, decode UTF-8, strip ANSI, split, drop empties. Each line gets a monotonic id and `isError` = lowercase contains any of `error, exception, failed, failure, fatal, traceback, panic:, econnrefused, eaddrinuse`. Keep last **5 000** lines. Filter = case-insensitive contains. Footer counts shown/error lines of the filtered set. No animation on append; always scroll to tail.

### 4.7 Timers and periodic work

| Timer | Interval | Where | Behaviour |
|---|---|---|---|
| Live refresh tick | 30 s | ContentView.swift:141, 664 | Only if window visible (not occluded) and either no sheet or Ports sheet open → `refreshLive()`: `state` for every project (→ `liveProjects`), `ports`, `overlaps`. Disk is never on this path. |
| Health poll | 5 s (3 s request timeout) | Engine.swift:375 | above |
| Uptime | 1 s | Views.swift:123 | `HH:MM:SS` from `epoch` (engine unix seconds); `—` if epoch 0; clamp ≥0; only the label re-renders |
| Log tail | 200 ms delay, then 1.5 s | RunSheet.swift:299 | above |
| Run sheet auto-close | 0.8 s after success | RunSheet.swift:87 | failure leaves it open |
| Scan done auto-close | 650 ms | ScanSheet.swift:184 | |
| Update offer wait | poll 500 ms up to 60 s | ContentView.swift:325 | wait for no sheet before presenting Update; give up after a minute |
| Login env deadline | 5 s | Engine.swift:83 | macOS-only concern |

### 4.8 Project editor logic (ProjectEditor.swift)

- Dirty keys = keys whose value differs from loaded; Save writes only those, sorted, stopping at the first failure; shows the first line of the error.
- Bool fields are "1"/"0".
- Port offset note: parse TARGETS lines `name:port:…` (field 2 as int). No targets → "Shifts every port this project declares, and rewrites {port} in its commands." Offset 0 → "Declared: 4173, 5173. A shift moves all of them together." Else → "Runs on 4173 → 4174, …. {port} in a command is rewritten to match."

### 4.9 Disk sheet derivations (Disk.swift)

total kb, spare kb (non-running), prunable = unique projects with any `gone` row; summary strings with correct singular/plural ("1 worktree").

### 4.10 Updater (Updates.swift) — needs Windows redesign, but the rules carry over

- `Version`: strip leading `v`; split on `.`; each piece's leading digits; stop at first non-numeric piece; missing components = 0 when comparing (1.3 == 1.3.0).
- `Build.isDevelopment` from a bundle key; dev builds never check on launch and `checkNow` reports "development build".
- Launch check: once per process, only if setting `updates.check` (default true), silent on any failure; available only if remote > installed.
- Manual check: reports up-to-date / failed(reason) / available.
- Fetch `GET https://api.github.com/repos/aosmcleod/runbranch/releases/latest`, headers `Accept: application/vnd.github+json`, `User-Agent: Runbranch/<ver>`, 15 s timeout, no cache. Reject draft/prerelease; pick asset **by name** `Runbranch-<ver>.dmg` (Windows would need its own asset name); sha256 from `digest` "sha256:<hex>".
- Install: pre-flight blocker (read-only location); download with progress (indeterminate when length unknown); verify SHA-256 if published; verify the payload is the same app and version; hand off to an external script that waits for this PID to exit then swaps; terminate, force-exit after 0.5 s.
- Errors mapped to readable text (no network / timed out / HTTP code).
- "Turn Off Update Checks" sets `updates.check=false`.
- What's new: key `updates.lastSeenVersion`. Empty → record installed, show nothing (fresh install). seen < installed → record, show every bundled entry with `seen < v <= installed` newest first. seen > installed (downgrade) → record, show nothing.
- `NotesText` parser: `>` prefix stripped, `[!…]` alert markers dropped; blank line = gap (collapsed, none trailing); `#…` heading; `- `/`* ` bullet; whole-line `**…**` heading; indented continuation appended to previous bullet; other lines joined into rewrapped paragraphs; inline `**bold**` and `` `code` ``.

### 4.11 Editors ("Open worktree in", Engine.swift:433)

Order VS Code, Cursor, Zed, Xcode, Claude Code, Terminal, Finder; only installed ones shown (bundle-id lookup; Claude Code = `claude` on PATH, opens Terminal `cd <path> && claude`). Windows needs detection by exe/App Paths registry/`where`.

### 4.12 Presentation / status item

Setting persisted; applying it installs/removes the tray item and, when not the initial launch and not tray-only, brings the window forward. Tray menu "Stop" stops the *selected* project (not necessarily a running one elsewhere). `healthLabel` is never populated — decide whether to implement (D10).

### 4.13 Not UI (skip or re-create as test tooling)

`Screenshot` (`--screenshot <path> --scene <main|settings|scan|logs|about|disk|ports|update|whatsNew>`) and `SelfTest` (`--selftest`, key/value report to `RB_SELFTEST_OUT`, 40 s watchdog). Env vars: `RB_ENGINE` (engine override), `RB_SCAN_ROOT`, `RB_SHOT_LOG`, `RB_SHOT_QUIET`, `RB_SELFTEST_OUT`. Worth keeping the CLI flags so the docs/test pipeline can be ported.

### 4.14 Discrepancies noticed while reading

1. README says "A project whose ports are taken shows a warning in the sidebar"; the code (Ports.swift:153–156, ContentView.swift:1108) deliberately has no sidebar warning.
2. `docs/img/about.png` does not show the About panel.
3. ⌘R (menu Refresh) only reloads; ⌘⇧R (toolbar) also runs `refresh` in the engine. Two refreshes with different depth.
4. ⌘, is bound twice (menu command and hidden background button).
5. `MenuBarController.healthLabel` is dead.
6. ⌘1–9 follow `projects` array order, not the Running/Favourites/Projects sidebar order.

---

## 5. Decisions for the product owner

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | **How the engine runs on Windows.** `runbranch.sh` is bash and assumes lsof/ps/du, macOS paths. This blocks everything else. | (a) Require Git for Windows and run `bash.exe runbranch.sh`; (b) run inside WSL (paths and ports cross a VM boundary); (c) port the engine to PowerShell/C# | (a) for a first cut, with the C# `Engine` class kept as the single seam so (c) can replace it later. Confirm the engine owner will make it Git-Bash-safe (lsof → netstat/Get-NetTCPConnection). |
| D2 | **Sheets as ContentDialogs or windows.** | (a) ContentDialog for everything (closest to Mac sheet, one-at-a-time matches the Sheet enum); (b) Logs and Run as separate resizable windows | (a), with size resources overridden; revisit Logs as a window only if users want it side by side with the browser. |
| D3 | **Sidebar control.** | (a) `NavigationView` Left mode with expandable parents for Running/Favourites/Projects; (b) custom `ListView` with collapsible group headers | (a): pane toggle, Mica and compact mode for free; accept that headers collapse via a parent item chevron rather than a header chevron. |
| D4 | **Menu bar commands.** Windows apps rarely have a menu bar. | (a) Put a `MenuBar` (File/View/Help) in the title bar; (b) no menu bar — keep everything in the ••• flyout plus `KeyboardAccelerator`s | (b). Add "About Runbranch", "Check for updates…", "Scan for projects…" and "Open projects folder" to the ••• menu, since the Mac app menu has no other home. |
| D5 | **Keyboard shortcuts.** | ⌘→Ctrl everywhere, or Windows-idiomatic keys | Ctrl+N add, Ctrl+Shift+N scan, Ctrl+, project settings, Ctrl+1–9 projects, **F5 = full refresh** (the toolbar one) and Ctrl+R = reload, Ctrl+. or Shift+F5 = stop (pick one; I lean Shift+F5, the VS "stop" key, and keep Ctrl+. as a secondary), Ctrl+F focuses search (no Mac equivalent, but expected on Windows). |
| D6 | **Where the app lives (Dock / Menu bar).** | Rename to Taskbar only / Taskbar and notification area / Notification area only; close behaviour | Keep the three modes with Windows wording, default Taskbar only (matches Mac default). In the tray modes, closing the window hides to the tray; say so once with a toast or InfoBar. |
| D7 | **Visual language.** Liquid Glass does not exist on Windows. | (a) Fluent/Mica: cards, accent buttons, 4–8 px radii; (b) imitate the Mac look | (a). Mica window, RunStrip as a card, AccentButtonStyle for primary, custom red style for destructive. Keep badge colours (GitHub PR colours are product semantics, not platform chrome). |
| D8 | **Engine error presentation.** | (a) Modal ContentDialog like the Mac alert; (b) dismissible `InfoBar` (Severity=Error) across the top of the detail pane | (b) for non-destructive failures (favourite, prune, separate), keep a dialog only where the user is mid-flow. InfoBar is the Windows idiom and doesn't block. Low stakes either way. |
| D9 | **SYMBOL vocabulary in configs.** `.conf` files store SF Symbol names and may be committed and shared with Mac users. | (a) Keep SF names as the stored value and map them to glyphs on Windows; (b) store Windows glyph codes | (a). Configs stay cross-platform; the Windows picker shows the same 137 names mapped to Fluent glyphs, and unknown names fall back to the package glyph. |
| D10 | **Tray menu content.** Mac shows only the *selected* project and a dead health line. | (a) Mirror exactly; (b) list every running project with its health and a Stop per run | (b) is more useful and cheap (the data is in `liveProjects` + state), but it is a behaviour change; if parity is the goal, do (a) and fix the health line. I recommend (a) plus the health line for v1, (b) as a follow-up for both platforms. |
| D11 | **Updater and distribution.** DMG + bash swap script do not apply. | (a) MSIX + `.appinstaller` auto-update; (b) Velopack (zip/Setup.exe, delta updates, GitHub Releases source); (c) plain installer + "download from GitHub" link | (b) Velopack: it keeps the "check GitHub latest release, verify, swap, restart" shape and works unpackaged. Code signing / SmartScreen is the Windows version of the Gatekeeper problem and needs a call on buying a certificate. |
| D12 | **Packaged vs unpackaged app.** Affects settings storage, tray, file access, and D11. | Packaged (MSIX) / unpackaged | Unpackaged with Velopack, settings as JSON in `%LOCALAPPDATA%\Runbranch`. Decide together with D11. |
| D13 | **"Open worktree in" list.** | Which editors | VS Code, Cursor, Zed, Visual Studio (if a .sln is present), Windows Terminal, Claude Code (in Windows Terminal), File Explorer. Drop Xcode. |
| D14 | **Platform wording.** "Finder", "Dock", "menu bar", "Reveal … in Finder". | — | "Show in File Explorer", "Open folder", "taskbar", "notification area". Update the strings rather than keeping Mac terms. |
| D15 | **Search placement.** | (a) AutoSuggestBox in the TitleBar (Explorer/Settings style); (b) above the branch list | (a), always expanded on wide windows, hidden below ~900 px. |
| D16 | **About.** | ContentDialog vs small window vs a section in a Settings page | ContentDialog; there is no Settings page to host it (D4 keeps preferences in the ••• menu). |
| D17 | **Primary action placement.** | Keep the Mac bottom action bar vs a top CommandBar | Keep the bottom bar: the primary button's position is part of the flow (select branch → Return/Start), and Windows has no convention it would break. |
