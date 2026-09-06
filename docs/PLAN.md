# Design notes and roadmap

Written 2026-09-05, after a pass over Finder, Ulysses, Messages, Stocks, Voice
Memos and the standard open panel, plus a scan of the tools already in this
space.

---

## 1. What the native apps actually do

Dissecting the screenshots rather than describing them in the abstract.

| App | The pattern | What we take |
|---|---|---|
| **Finder** | Toolbar carries the *actions*: nav, title, view switcher, share, tag, `•••` overflow, search. Sidebar is sectioned (Recents/Shared · Favorites · Locations) with an SF Symbol per row. | Actions move to the toolbar. Filters stop being checkboxes in the body. Sidebar gets sections and symbols. |
| **Ulysses** | Three panes. The middle list is *rich*: title, a two-line preview, a date. Word count sits quietly top-right. Nested disclosure in the sidebar. | A branch row can carry a second line — PR title or last commit subject. A quiet metric in the corner. |
| **Messages** | Search at the top of the sidebar. Rows are avatar + name + timestamp + preview. Pinned items as a separate affordance. | Search. Richer rows. Pinning frequently-run branches. |
| **Stocks** | Sidebar rows pack a sparkline and a coloured change badge into one line. The detail is a header, a segmented range, a chart, then a **stats grid** — Open, High, Low, Vol, P/E, Mkt Cap, 52W H/L, Yield, Beta, EPS. | The stats grid is the model for a running project: uptime, health, ports, PIDs, memory, disk. This is the biggest idea on the page. |
| **Voice Memos** | Sidebar row carries a **count badge** (16). The detail toolbar is icon-only: share, favourite, delete, settings, transcript, waveform. A waveform gives the content a shape. | Count badges. Icon-only detail toolbar. A live log strip is our waveform. |
| **Open panel** | The preview pane is metadata: kind, size, created date. | An inspector: worktree size on disk, HEAD sha, created, last run. |

**The through-line:** none of these apps put configuration in the body of the
window. Options live in the toolbar, in a `•••` menu, or in a popover. The body
is *content*. Ours currently spends a whole row on two checkboxes.

---

## 2. UI changes

### 2.1 Toolbar (replaces the checkbox row)

Left to right: sidebar toggle · project name · **search field** ·
filter menu (`line.3.horizontal.decrease.circle`) · refresh
(`arrow.clockwise`) · overflow `•••` (`ellipsis.circle`).

- **Filter menu** — Show merged · Show older than a week · Show everyone's
  branches. Toggles with checkmarks, exactly like Finder's view options.
- **Overflow** — Reveal worktree in Finder · Open in editor · Copy URL ·
  Open logs · Remove worktree · Project settings · Edit config file.

### 2.2 Sidebar

- Sections: **Running** (only when non-empty) then **Projects**.
- SF Symbol per project, colour-coded by kind.
- A count badge showing branches ready-to-run (built worktrees).
- Under a running project, a live **uptime**.

### 2.3 Branch rows

Two lines, as Ulysses and Messages do:

```
⣿  fx980/enforce-fs-ui-facade      [open] [me] [ready]        1h
   Enforce the fs-ui facade across web and admin
```

Second line is the PR title, falling back to the last commit subject. This is
the single biggest information gain available — right now a row tells you a
branch name and nothing about what is *in* it.

### 2.4 Running detail — the Stocks grid

When a project is running, the detail pane leads with a stats strip:

```
UPTIME      HEALTH     WEB              API            DISK
00:14:32    ● healthy  localhost:3000   localhost:4000  1.2 GB
```

Uptime ticks. Health is polled against each target's health path — green,
amber while starting, red when a probe fails. Ports are buttons.

### 2.5 Everything else

- `ContentUnavailableView` with a symbol for every empty state.
- Keyboard: `⌘R` run · `⌘.` stop · `⌘F` search · `⌘1…9` project · `⌘⌫` remove
  worktree · `Space` Quick Look the diff.
- Notifications when a run becomes ready or fails.

---

## 3. Functionality — the whole idea list

Nothing here is committed; this is the menu to choose from.

**Status and visibility**
1. Ticking uptime clock.
2. Live health polling with a coloured dot per target.
3. Menu bar extra: what is running, stop it without opening the window.
4. Notification on ready / failed.
5. Live log viewer — tail, search, copy, reveal, per target.
6. Resource use per run (CPU/memory), the way Activity Monitor shows it.

**Getting into the code**
7. Open worktree in editor — VS Code, Cursor, Zed, JetBrains, Terminal, Finder.
8. Copy URL, open all URLs.
9. Quick Look the diff against the default branch.
10. Open the PR on GitHub.

**Housekeeping**
11. Disk usage per worktree and total reclaimable, with a cleanup sheet.
12. Auto-stop runs idle for N hours.
13. Prune worktrees whose branch is now merged.

**Setup and onboarding**
14. Project scan: walk a directory, find git repos, *guess* a config from what
    is in them, offer to add.
15. Config editor UI with validation, so a new project needs no text editor.
16. `doctor` per project: check every declared command exists before you need it.
17. In-repo config (`.launcher.toml` committed to the project) so a team shares
    one definition, with the local file as an override.

**Running**
18. Post-start hooks — seed data, open a specific path, run a smoke test.
19. Per-run environment overrides (run this branch against staging).
20. Port auto-assignment when the default is taken, instead of refusing.
21. Restart a single target without restarting the run (Overmind's best idea).

---

## 4. Repo setups worth supporting

From a scan of how projects actually declare "what to run":

| Ecosystem | Declaration | Notes |
|---|---|---|
| Node | `package.json` scripts | npm / pnpm / yarn / bun; turbo and nx use `--filter` |
| Procfile | `web: …` / `worker: …` | Foreman, Overmind, Hivemind, Heroku. **A Procfile is already a TARGETS list** — parse it directly |
| Python | uv / poetry / pipenv / venv | Django, Flask, FastAPI |
| Ruby | `bin/dev`, bundler | Rails ships a Procfile.dev |
| Go / Rust | `go run`, `cargo run` | trivial single target |
| PHP | Laravel Herd / Valet / Sail | Sail is docker compose |
| Compose-only | `docker-compose.yml` | the whole app is the stack |
| Make | `make dev` | still very common |
| Version managers | mise, asdf, nvm, fnm | must run *inside* the worktree so `.nvmrc` applies |
| Nix | devenv, flakes | `devenv up` is one command |

**Implications for the config format**
- `PROCFILE=1` — derive targets from a Procfile. Free support for a large slice.
- `RUNTIME="mise"` / `"fnm"` / `"asdf"` — activate the version manager in the
  worktree before running anything, so a repo's pinned version is honoured.
- Keep `INSTALL` and target commands free-form strings. Nothing above needs a
  bespoke integration; they all need "run this string in this directory".

---

## 5. Where we stand

| Tool | What it does | Overlap |
|---|---|---|
| [Grovr](https://github.com/j1king/grovr) | Native macOS worktree manager, launches editors | Worktrees + native UI. **Does not run or supervise servers.** |
| [Forest](https://github.com/ricwo/forest) | macOS worktree app | Worktrees only |
| [Worktrunk](https://worktrunk.dev/) | CLI, worktrees for agents, post-start hooks incl. dev servers | Closest on *behaviour*, but CLI and agent-shaped |
| [git-worktree-runner](https://github.com/coderabbitai/git-worktree-runner) | Bash: worktree, config copying, install, editor | Closest on *engine*. No GUI, no supervision |
| [Conductor](https://conductor.build/) / [cmux](https://cmux.com/) | Parallel AI agents in worktrees | Adjacent — the job is agents, not demos |
| [Tower](https://www.git-tower.com/help/guides/worktrees/overview/mac) 12.5 | Worktrees inside a git client | Worktrees only |
| Overmind / Hivemind / Foreman / mprocs / lpm | Procfile process managers | Supervision only. **No worktrees.** |
| devenv / mise / Tilt | Environment and stack managers | Environments, not branches |

**The gap.** Worktree tools do not run servers. Process managers do not do
worktrees. Agent tools are about agents. Nothing owns *"put this branch on a
port, tell me when it is up, and never touch my checkout"* with a native UI.

That is a real, narrow, defensible position, and the honest pitch is
simplicity: one window, no daemon, no YAML, a bash engine you can read.

---

## 6. Plan

Sequenced so each phase ships something usable.

### Phase 1 — Native chrome
The screenshots' actual lesson. No new capability, large perceived gain.
1. Toolbar: search, filter menu, refresh, `•••` overflow. Remove the checkbox row.
2. SF Symbols throughout; sidebar sections; empty states.
3. Keyboard shortcuts.

### Phase 2 — Say what is happening
4. Ticking uptime.
5. Health polling with a status dot per target.
6. Stats strip in the running detail.
7. Log viewer.

### Phase 3 — Second line, and getting into the code
8. PR title / commit subject on every row (needs a wider `gh` query, cached).
9. Open in editor / Finder / Terminal.
10. Copy and open URLs; open the PR.

### Phase 4 — Breadth of projects
11. Procfile-derived targets.
12. `RUNTIME` version-manager activation.
13. Project scan and config guessing.
14. `doctor`.

### Phase 5 — Ship it
15. Rename (see below), MIT licence, docs, screenshots.
16. In-repo `.launcher.toml`.
17. Release: signing and notarisation, or an honest "right-click → Open" note.
    Homebrew cask if it earns one.

### Naming
`project-launcher` is generic and certainly taken. The tool puts a branch on
stage without disturbing the real one, so the theatre metaphor fits:
**Greenroom** (where a performer waits before going on) · **Understudy**
(stands in for the real thing) · **Sidestage** · **Matinee**.
