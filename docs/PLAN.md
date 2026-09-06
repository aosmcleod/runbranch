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

**Decided: `runbranch`.** It says what the tool does in one word, it is a verb,
and it does not collide with the theatre metaphors that were all either taken
or too cute.

---

## 7. The icon

### What Apple actually wants now

macOS 26 changed app icons substantially, and the icon we have is built the
*old* way — one flat image with gradients, highlights and shadow baked in.

The current model is **layered**. You supply flat foreground and background
layers with no lighting of your own, and the system applies specular
highlights, blur and shadow. Layers are authored in **Icon Composer** (ships
inside Xcode; it is at `Xcode.app/Contents/Applications/Icon Composer.app`) and
exported as a `.icon` document. From those layers the system derives the
appearance variants: **Default, Dark, Clear Light/Dark, Tinted Light/Dark**,
plus Light/Dark Transparent new in macOS 26.

Consequence for us: **stop baking gradients and shadows.** Everything the
current icon does by hand is now the system's job, and doing it ourselves is
what makes an icon look a version behind.

### The blocker on your SF Symbols idea

Apple's SF Symbols licence is explicit:

> You may not use SF Symbols — or glyphs that are substantially or confusingly
> similar — in your app icons, logos, or any other trademark-related use.

So SF Symbols go everywhere in the **UI** — toolbar, sidebar, rows, that is
what they are for — but the **app icon must be original artwork**. For a tool
we intend to publish, this is not a nicety; shipping an SF Symbol as an icon is
a licence violation.

That does not kill the concept. A git branch and a play triangle are universal
shapes, not Apple's. The rule is only that we draw them ourselves rather than
tracing `arrow.trianglehead.branch`. The current glyph is already hand-drawn
SVG, so we are clean today and must stay that way.

### The concept

Your traffic-light idea is the strongest part, because it can carry *meaning*
rather than decoration. runbranch's whole job is state: stopped, starting,
running.

**Preferred — "branch with signal nodes".** A branch line diverging from a
trunk, its three nodes coloured red · amber · green along its length, reading
left to right as the run's own progression. At a glance it is a branch; on
inspection it is a status. The green terminal node doubles as the "go" end.

**Alternative — "play through the branch".** The trunk and branch in a neutral
tone, with a single vivid play triangle at the branch's end. Simpler, reads
smaller, but says nothing about state.

Testing/demo glyphs (flask, beaker, checkmark-seal) are worth prototyping but I
suspect they misdirect: this tool does not test anything, it *runs* things.

### The non-GUI path — verified

Icon Composer is a GUI app and `.icon` is undocumented, but it turns out we do
not need either. `actool` — which ships with Xcode — compiles a hand-written
asset catalogue straight from the command line, **including appearance
variants**:

```
assets/AppIcon.appiconset/
  Contents.json          # hand-written; images tagged with appearances
  light-512x512@2x.png   # generated from SVG by sips
  dark-512x512@2x.png
```

```bash
xcrun actool assets/Icons.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist /tmp/icon.plist
```

Verified: this emits `Assets.car` carrying the light and dark variants, plus an
`AppIcon.icns` fallback. `Info.plist` needs `CFBundleIconName` alongside the
existing `CFBundleIconFile`. Everything stays a shell script and a diffable SVG.

*Dark is confirmed working. `tinted` uses the same mechanism and is untested —
worth trying, not worth promising.*

### The graphic set

The app icon is not the only place the mark appears. `make-icons.sh` produces
all of it from two SVG sources:

| Source | Output | Used by |
|---|---|---|
| `assets/icon.svg` — full tile, background + glyph | `Assets.car`, `AppIcon.icns` | the app |
| | `docs/img/icon-512.png` | README, the Homebrew cask |
| `assets/mark.svg` — glyph only, **transparent background** | `docs/img/mark-{256,512,1024}.png` | README header, GitHub social preview, docs, anywhere on a light or dark page |

Two sources rather than one because they are genuinely different drawings: the
tile needs its glyph inset within the icon grid's safe area, while the mark
needs to fill its own bounds with no padding. Deriving one from the other by
cropping gives you a mark that is mysteriously small.

### Plan

1. Draw the layers flat — background and foreground as separate SVGs, **no
   gradients, no shadow, no specular highlight**; the system supplies those.
2. Draw `mark.svg` separately, transparent, glyph filling its bounds.
3. `make-icons.sh`: SVG → PNG (`sips`) → `Contents.json` → `actool`.
4. Test at 16/32/128/512 against a Dock full of real icons, light and dark.

---

## 8. Revisions from the runbranch vision

Adopting most of it. Four things need a harder look before they go in.

### Adopt

| Idea | Why |
|---|---|
| **Orphan reclamation** on launch — reclaim ports and processes left by a crash, sleep or force quit | The best idea in the document. Nobody should hunt with `lsof` |
| **`.runbranch` in the repo**, local file as override | Versioned, diffable, reviewable. Necessary for the open-source story |
| **Config proposed from the repo** — read package manager, lockfile, scripts, Procfile, compose, version pins | Removes the blank page. Frame as *proposes*, not "you don't write the config" — detection will guess wrong often enough that overselling it will annoy people |
| **`SEED`** | An empty app is not worth looking at. Cheap to add |
| **Remote and fork branches**, fetched on selection | A colleague's PR is the whole use case, and today we only list local branches |
| **The security note** about sourcing shell config | Correct, and better said up front than discovered |

### Push back

**1. Port stepping will silently break auth.** "Later runs step up from the
port you named" is a good default in general and wrong for the app it was
written for. Studio's Clerk dev instance accepts exactly **one** primary
origin — `localhost:3000`. A second run on `:3001` gets a sign-in page that
cannot complete. The same applies to any baked origin: `NEXT_PUBLIC_API_URL`,
CORS allowlists, OAuth redirect URIs.

→ Make it a declared property, `PORTS="fixed"` or `PORTS="stepping"`, defaulting
to **fixed**. A project opts into parallel runs once it can survive them.

**2. Per-run databases are a bigger feature than one bullet.** "Its own
database, thrown away with the worktree" needs the launcher to know which
environment variable carries the URL, how to create and drop, and what to seed
from — and the answer differs per engine. It is genuinely the fix for the
migration-drift problem, so it should exist, but as an explicit, Postgres-first
feature (`DB_URL_VAR`, `DB_TEMPLATE`) in a late phase — not as an implied
property of running two things at once.

**3. "Nothing survives a quit that you didn't ask to keep" contradicts the
current design,** where servers are deliberately detached and outlive the app.
That is a real choice, not an oversight: you close the launcher and the demo
keeps serving. The vision's version is tidier to reason about; ours is more
useful. **Decision needed.** My recommendation: keep detached survival, make it
explicit in the UI ("still running after quit"), and lean on orphan reclamation
to stop that becoming litter.

**4. "A new hire clones and runs"** is true only once they have installed
runbranch and have whatever `COPY_FILES` names — which is gitignored and
therefore not in the clone. Worth softening; the config being in-repo does not
solve secret distribution, and implying it does will bite someone.

---

## 9. Implementation plan

Each item is a commit-sized change. Ordered so nothing depends on something
later.

### Phase 1 — Native chrome ✅ done
| # | Change | Touches |
|---|---|---|
| 1.1 | Toolbar: search field, filter `Menu`, refresh, `•••` overflow. Checkbox row deleted | Swift |
| 1.2 | SF Symbols in sidebar and menus; sectioned sidebar (`Running` / `Projects`) | Swift |
| 1.3 | `ContentUnavailableView` for no-project, no-branches and no-search-match | Swift |
| 1.4 | Shortcuts: `⌘R` run · `⌘.` stop · `⌘F` search · `⌘⇧R` refresh · `⌘1…9` project | Swift |
| 1.5 | `paths` subcommand so the app never hardcodes the state layout | engine |

### Phase 2 — Say what is happening ✅ done
| # | Change | Touches |
|---|---|---|
| 2.1 | `state` emits a `run` line plus one `target` line each: port, health path, pid, alive. `EPOCH` added to the state file | engine |
| 2.2 | Ticking uptime, driven by a local clock rather than polling the engine | Swift |
| 2.3 | Health polled every 5s per target; a first non-answer reads as *starting*, a later one as *failing* | Swift |
| 2.4 | Stats strip: uptime · health · a button per target · logs | Swift |
| 2.5 | Log viewer — live tail, per-target picker, filter, copy, reveal | Swift |
| 2.6 | `reclaim` subcommand, run before the first draw | engine |
| 2.7 | `SYMBOL` per project, used in the sidebar | engine + configs |

### Phase 3 — Second line
| # | Change | Touches |
|---|---|---|
| 3.1 | ✅ PR title, number and author cached; commit subject as fallback | engine |
| 3.2 | ✅ Two-line branch rows | Swift |
| 3.3 | ✅ Remote branches listed. Those with an open PR show by default (17 of 629 on Studio); the rest behind a filter. **Fork branches still to do** — they need `gh` head-repo data, not `refs/remotes` | engine |
| 3.4 | ✅ Open worktree in VS Code / Cursor / Zed / Xcode / Terminal / Finder (only those installed are listed); open the pull request | both |

### Phase 4 — Breadth
| # | Change | Touches |
|---|---|---|
| 4.1 | ✅ `PROCFILE=1` derives targets, foreman-style port assignment | engine |
| 4.2 | ✅ `RUNTIME` activation inside the worktree | engine |
| 4.3 | ✅ `SEED`. `PORTS` key parsed; only `fixed` behaves, stepping is Phase 5 | engine |
| 4.4 | ✅ `doctor` | engine |
| 4.5 | ✅ `propose` reads a repo and guesses a config; `add` writes it; `scan` finds repos not yet declared. **Add project…** in the app opens a folder picker, writes the config and opens it for correction | engine + Swift |

### Phase 5 — Isolation
| # | Change | Touches |
|---|---|---|
| 5.1 | ✅ `DB_URL_VARS`, `DB_TEMPLATE`, `DB_ADMIN_USER`. Postgres only. Verified on Studio: the run database took the branch's 169 migrations while the shared one kept its 173 | engine |
| 5.2 | Parallel runs of one project when `PORTS="stepping"` | engine + Swift |

### Phase 6 — Ship
| # | Change | Touches |
|---|---|---|
| 6.1 | Rename everything to `runbranch` | all |
| 6.2 | `make-icons.sh`: flat layered art, `actool` appearance variants, plus the transparent mark for docs | assets |
| 6.3 | `.runbranch` in-repo config with local override | engine |
| 6.4 | MIT licence, `docs/config.md`, screenshots, honest README | docs |
| 6.5 | Release: signing and notarisation, or a documented right-click → Open | build |
