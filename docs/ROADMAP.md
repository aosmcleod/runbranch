# Roadmap

A pipeline rather than a wishlist: what ships in v1, what earns a point
release, and what is a year out. Each item says why it is worth doing, because
an idea with no reason behind it tends to get built badly.

Written 2026-09-06. `PLAN.md` holds the design notes this came out of;
`VISION.md` holds the README the tool should earn.

---

## v1 — what "finished" means

The bar: someone who is not me can install it, point it at their repo, and
demo a colleague's branch without reading anything.

| | Item | Why |
|---|---|---|
| 1.1 | ✅ **Project editing in the app** — every config key, in a sheet, via engine `get`/`set` | Editing a `.conf` by hand was the largest remaining gap |
| 1.2 | ✅ **Onboarding** — welcome screen when nothing is declared, then a scan that proposes projects with progress | The blank first launch was the worst moment in the app |
| 1.3 | ✅ **Sidebar sections** — Running, Favourites, Projects; hover `+` to add; pin from the context menu | Four projects fit in one list. Twenty do not |
| 1.4 | **Menus** — About, Preferences, Scan for projects, Reveal config | An app with no menu bar items reads as unfinished, and About is where the licence and version belong |
| 1.5 | **Docs** — README with the logo and screenshot, config reference | It is going public |
| 1.7 | ✅ **Tests** — `tests/engine.sh`, 34 assertions, each remembering a real bug; `tools/lint.sh` for the mistake this file keeps making | Six engine bugs reached the app before this existed, and one of them ate a config file |
| 1.8 | ✅ **Open-source guidelines** — CONTRIBUTING, CODE_OF_CONDUCT, TESTING, issue and PR templates | A repo without them asks every contributor to guess |
| 1.6 | **Design and code review** — commonise, refactor, delete | Two months of accreted decisions want one pass |

---

## v1.1 — the things you notice on day two

| | Item | Why |
|---|---|---|
| 2.1 | **Menu bar mode** — optional item showing what is running; optionally *only* the menu bar | A demo runs for an hour while you use other apps. The window is not where you want the status |
| 2.2 | **Per-target restart** — restart web without restarting the api | Overmind's best idea. A Next rebuild should not cost a database connection |
| 2.3 | **Notifications** — ready, failed, and "still running after an hour" | The run outlives the window on purpose; it should be able to say so |
| 2.4 | **Log improvements** — follow toggle, wrap toggle, jump to first error | The viewer works; it does not yet help you read |
| 2.5 | **Disk usage panel** — size per worktree, total reclaimable, merged-branch prune | 1.2GB each, and nothing currently tells you the total |
| 2.6 | **Remove a project** — from the right-click menu, with a confirmation that says what it does and does not delete: the config goes, the repository does not | Adding is in the app; removing still means deleting a file by hand |
| 2.7 | **Quick Look the diff** — space on a branch shows what changed against the default | Deciding whether to run a branch is the step before running it |

---

## v1.2 — breadth

| | Item | Why |
|---|---|---|
| 3.1 | **Fork branches** — pull requests from forks, fetched on demand | The one gap in "review a colleague's PR". Needs `gh` head-repo data and a second remote |
| 3.2 | **`PORTS="stepping"`** — two branches of one project at once | Comparing a refactor against `main` is the case worth having. Needs multi-run state and port rewriting inside commands |
| 3.3 | **Per-run databases beyond Postgres** — MySQL, SQLite file-per-run | Postgres-only is an arbitrary limit; SQLite is nearly free |
| 3.4 | **`doctor --fix`** — write the `~/.npmrc` token, install the missing runtime | doctor names the command; it could just run it |
| 3.5 | **Environment overrides per run** — point a branch at staging data | Sometimes the interesting bug needs real data |

---

## v1.3 — for other people's machines

| | Item | Why |
|---|---|---|
| 4.1 | **Notarisation and a signed release** | Right-click-to-open is a bad first impression for a tool about first impressions |
| 4.2 | **Homebrew cask** | `brew install --cask runbranch` is the difference between trying it and not |
| 4.3 | **Sparkle updates** | Nobody returns to a GitHub releases page |
| 4.4 | **Windows/Linux engine** — the bash engine is close to portable; the UI is not | The engine is the valuable half. A CLI-only Linux port is plausible |

---

## v1.4–1.5 — depth

| | Item | Why |
|---|---|---|
| 5.1 | **Run history** — what ran, when, for how long, what failed | "It worked yesterday" deserves an answer |
| 5.2 | **Resource use per run** — CPU and memory per target | Three Next servers on one laptop; something has to give and you should know which |
| 5.3 | **Templates** — "Next + Postgres", "Rails + Procfile" as starting configs | Most stacks are one of a dozen shapes |
| 5.4 | **Team config validation in CI** — `runbranch doctor` as a GitHub Action | A `.runbranch` that has rotted is worse than none |
| 5.5 | **Warm pool** — keep one worktree pre-installed so the next run starts instantly | The install is the only slow part left |

---

## Stretch — a year out, or never

Recorded because they are interesting, not because they are planned.

- **Shareable runs** — a tunnel so a colleague can click the thing. Directly
  against the "not a sharing tool" principle, which is exactly why it is worth
  arguing about rather than quietly adding.
- **Agent integration** — hand a worktree to Claude Code with the run already
  up, so it can see the app it is editing. The adjacent tools all start here;
  we would arrive from the opposite direction.
- **Snapshot and restore** — freeze a run's database so a demo always opens on
  the same data. The demo-day feature.
- **Screenshot and video capture** — the app can already photograph itself for
  its own README. Turning that on the *demo* would produce PR evidence for free.
- **Multi-machine** — run on the beefy desktop, view from the laptop. This is
  the "network projects" idea done honestly: not a remote filesystem, but a
  remote runbranch you drive.
- **`runbranch open <pr-url>`** — paste a pull request link, get it running.
  The shortest possible path from review request to looking at the thing.

---

## Quality-of-life, unsorted

Small, cheap, and each removes a papercut. Most are an afternoon.

- Remember window size and the selected project between launches
- `⌘⌥C` copy the running URL; `⌘⇧O` open it
- Double-click a branch to run it
- Right-click a project → Reveal in Finder, Open in editor, Edit config
- Show the commit sha and author avatar on a row
- "Copy as command" — the `runbranch run …` line for what is on screen
- Confirm before stopping a run that has been up for hours
- Dim branches whose worktree is missing rather than hiding them
- A relative-time tooltip on ages ("2d" → the actual date)
- Empty-state action buttons, not just text
- Respect Reduce Motion for the spinner and Increase Contrast for the badges
- Full keyboard navigation of the branch list, with type-to-select
- An `--json` flag on every engine subcommand, for scripting
- `runbranch doctor --json` so CI can consume it
- A `.runbranch` JSON-schema file, so editors can complete the config
