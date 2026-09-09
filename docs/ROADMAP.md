# Roadmap

A pipeline rather than a wishlist: what ships in v1, what earns a point
release, and what is a year out. Each item says why it is worth doing, because
an idea with no reason behind it tends to get built badly.

Written 2026-09-06, revised through publication. The design notes and the
aspirational README this came out of are in the git history — they described
building the thing rather than the thing, and the README covers what exists
while this covers what does not.

Near-term work — the open v1 items and the whole v1.1 band — is tracked in
[issues](https://github.com/aosmcleod/runbranch/issues) now that there is a
repository to track it in. This file keeps the reasoning and the long horizon,
which is what it is better at than a tracker. Where an item is filed, the issue
is the live one and this is the argument for it.

Revised 2026-09-09, after publication. Menus, menu bar mode, publication and
the port work shipped; running in place shipped and was not on this list at
all, which is the largest thing the original plan got wrong.

---

## v1 — what "finished" means

The bar: someone who is not me can install it, point it at their repo, and
demo a colleague's branch without reading anything.

| | Item | Why |
|---|---|---|
| 1.1 | ✅ **Project editing in the app** — every config key, in a sheet, via engine `get`/`set` | Editing a `.conf` by hand was the largest remaining gap |
| 1.2 | ✅ **Onboarding** — welcome screen when nothing is declared, then a scan that proposes projects with progress | The blank first launch was the worst moment in the app |
| 1.3 | ✅ **Sidebar sections** — Running, Favourites, Projects; hover `+` to add; pin from the context menu | Four projects fit in one list. Twenty do not |
| 1.4 | ✅ **Menus** — About, File items with shortcuts, Toggle Sidebar, Help to the repository; no New Window, no window tabbing | An app with no menu bar items reads as unfinished, and About is where the licence and version belong |
| 1.5 | ✅ **Docs** — README with the logo and four screenshots, config reference, TESTING, ROADMAP | It is going public |
| 1.7 | ✅ **Tests (engine)** — `tests/engine.sh`, 112 assertions, each remembering a real bug; `tools/lint.sh` for the mistake this file keeps making | Six engine bugs reached the app before this existed, and one of them ate a config file |
| 1.8 | ✅ **Open-source guidelines** — CONTRIBUTING, CODE_OF_CONDUCT, TESTING, issue and PR templates | A repo without them asks every contributor to guess |
| 1.6 | ✅ **Design and code review** — one duplicated engine block removed, dead code deleted, home abbreviation commonised; the structural half is 1.10 | Two months of accreted decisions want one pass |
| 1.11 | ✅ **Publish it** — public at `aosmcleod/runbranch` under GPL-3.0, v1.0.0 tagged | Every other v1 item was justified by "it is going public". The release still has no installable artifact, which is [#3](https://github.com/aosmcleod/runbranch/issues/3) |
| 1.10 | **Decompose ContentView** — [#1](https://github.com/aosmcleod/runbranch/issues/1). 918 lines and 31 state properties in one view, in a 3,504-line file | Both bugs behind 1.9 lived in this view's state wiring. Splitting it is where the next ones stop happening |
| 1.9 | ⚠️ **A UI smoke test** — [#2](https://github.com/aosmcleod/runbranch/issues/2). `tests/ui.sh`, 8 assertions. Catches the duplicate window; does NOT catch the stale-render bug it was also written for | Half done, and the half it misses is recorded in the test file. Asserting the monitor passes while the render is stale — reintroducing that bug left the suite green. Catching it needs the drawn text, which neither an in-process accessibility walk nor System Events can reach |

### Why 1.9

The engine has 112 assertions. The app — around 3,500 lines of Swift — has
eight, none of which can see what is drawn, and on 2026-09-08 that cost two
real bugs:

- The run strip held the health monitor as a plain property rather than an
  `@ObservedObject`, so it never subscribed to changes and kept whatever it drew
  first. A healthy run read "Starting" indefinitely. The poll was returning 200
  the whole time; nothing was listening.
- Applying the saved presentation at launch called through to `openWindow`, so
  every start opened a duplicate window.

Neither was found by looking for it. The first surfaced because a screenshot
showed an amber dot next to a server that was demonstrably up; the second
because a crop region jumped from 660×540 to 1309×993 and the only explanation
was a second window. Both would have shipped.

The lesson is not "write more tests" in general. It is specific: this app's
state flows through `@Published` properties and window lifecycle, and both bugs
were in that wiring rather than in logic a unit test would reach. A smoke test
that launches the real app against the demo config and asserts four things
about the result would have caught both, and the screenshot pipeline already
does the hard part — it launches the app unattended and knows when it failed.

### Why 1.10

The review found the engine in reasonable shape — one duplicated block, since
removed, and no dead functions. The app is the imbalance:

- `ContentView` is 918 lines with 31 state properties, in a file of 3,504 —
  both larger than when this was written, which is the argument making itself.
- `Screenshot` and `Engine` are cohesive and would move out cleanly;
  `ProjectEditor` and `ScanSheet` are already separate types sharing one file
  only by habit.

Nothing here is broken, which is why it is 1.10 and not urgent. But it is the
same place both bugs behind 1.9 lived — a view holding 23 pieces of state has
no way to make an invalid combination unrepresentable, and the fix for the
earlier "mixed data while switching projects" bug was exactly that: collapsing
six independent properties into one atomically-swapped `ProjectSnapshot`.

The remaining state wants the same treatment, and the file wants splitting on
the boundaries the MARK comments already draw. Doing it needs a quiet session
rather than the end of a long one, because a mechanical-looking SwiftUI
refactor is precisely the kind of change that silently alters behaviour.

---

## What shipped that this plan did not contain

Worth recording separately, because it changed what the app is rather than
adding to it. The original plan described a tool that runs branches from
throwaway worktrees. It now runs them from a throwaway worktree *or* from the
checkout you are working in, and those are different products.

- **Running in place.** A branch that is the one currently checked out in the
  repository runs there, against the working tree as it stands — uncommitted
  changes included. This exists because a worktree is a snapshot: hot reload in
  a worktree cannot see code you are typing in your checkout, and the fix
  attempted first was to make Refresh do something it does not mean. There is
  no install, nothing is copied, and there is no per-run database, and the run
  strip has to say so, because those absences are surprising if you assume
  every run is isolated. Runbranch never switches a branch in a checkout it
  does not own; an in-place run of a ref that is not checked out is refused
  with the `git switch` line that would fix it.
- **Adopting a run Runbranch did not start.** A port answering when we expected
  it not to used to be an error. It is now attributable — to another project's
  run, to a foreign process, or to nothing identifiable — and the run can be
  adopted rather than fought with. This is what makes in-place runs usable at
  all, since the thing already holding the port is usually your own dev server
  or an agent's.
- **A ports view.** What is listening, on which port, belonging to what. Built
  because the port conflict dialogue needed the data anyway, and once the
  engine can answer the question there is no reason not to show it.

The follow-ups these opened are filed rather than planned here:
[#13](https://github.com/aosmcleod/runbranch/issues/13) — an in-place run does
not notice its branch being switched underneath it, and
[#14](https://github.com/aosmcleod/runbranch/issues/14) — Vite resolves a
different project root in place than it does in a worktree.

---

## v1.1 — the things you notice on day two

| | Item | Why |
|---|---|---|
| 2.1 | ✅ **Menu bar mode** — Dock, both, or menu bar only; status item with the current run, Stop, and a way back to the window | A demo runs for an hour while you use other apps. The window is not where you want the status |
| 2.13 | [#5](https://github.com/aosmcleod/runbranch/issues/5) **Keep the ports view current on a timer** — it is read on launch and after every operation, so a server started while the window sits idle is not noticed until something else happens | Each read is one `lsof` per declared port plus a `ps` to attribute it, so a tight poll is wasteful. Thirty seconds, or watching for a `kqueue` event, would do |
| 2.12 | [#6](https://github.com/aosmcleod/runbranch/issues/6) **Update a run to the branch's latest commit** — one action that re-checks-out the tip and restarts, plus showing in the strip when the worktree is behind | A worktree is pinned to the commit it was made at, so new commits need a stop and a start. Alec hit this expecting *Refresh* to do it, which only re-reads pull request metadata. Being able to see "3 commits behind" is half the value |
| 2.2 | [#7](https://github.com/aosmcleod/runbranch/issues/7) **Per-target restart** — restart web without restarting the api | Overmind's best idea. A Next rebuild should not cost a database connection |
| 2.3 | [#8](https://github.com/aosmcleod/runbranch/issues/8) **Notifications** — ready, failed, and "still running after an hour" | The run outlives the window on purpose; it should be able to say so |
| 2.4 | [#9](https://github.com/aosmcleod/runbranch/issues/9) **Log improvements** — follow toggle, wrap toggle, jump to first error | The viewer works; it does not yet help you read |
| 2.5 | [#10](https://github.com/aosmcleod/runbranch/issues/10) **Disk usage in the app** — `runbranch.sh disk` reports it; the app does not show it, and there is no prompt when it grows | On this machine: 3 worktrees, 1.9GB, 1.1GB of it not in use. The engine can now say so and nothing asks it. A prune of `gone` worktrees could be offered rather than waiting to be asked; "merged" deliberately stays out of it, since a squash-merge leaves a branch looking unmerged |
| 2.6 | ✅ **Remove a project** — right-click → Remove Project, with a confirmation naming the repository it will not touch; refused while running | Adding is in the app; removing still means deleting a file by hand |
| 2.7 | [#11](https://github.com/aosmcleod/runbranch/issues/11) **Quick Look the diff** — space on a branch shows what changed against the default | Deciding whether to run a branch is the step before running it |
| 2.10 | ✅ **Worktree names can collide** — `worktree_slug` now records the owning ref in a meta file and gives a second, colliding ref a digest suffix | Found by probing, not by hitting it. The per-run *database* name had the same bug and was fixed with it, which is the part that would have corrupted data rather than just confusing the UI |
| 2.11 | ✅ **The app has no way to report an error** — `Engine.failure` routes 11 previously-silent paths to an alert that names the command | Every other error path in this project names the command that fixes it. The app was throwing that away for anything that was not a streamed run |
| 2.9 | ⚠️ **Port allocation across projects** — [#12](https://github.com/aosmcleod/runbranch/issues/12). The engine half shipped: `PORT_OFFSET` shifts every declared port, `{port}` in a command is rewritten, `doctor` warns on overlap, and a taken port offers switch / take over / run elsewhere | Framework defaults collide — three projects here all want 5173 and two want 3000. What is left is that the user still picks the number by hand, in a file, which is the half that made it worth doing |

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
| 4.1 | **Notarisation and a signed release** — needs a Developer ID; local builds already sign with a self-signed identity via `tools/make-signing-identity.sh`, which is what makes a TCC grant survive a rebuild | Right-click-to-open is a bad first impression for a tool about first impressions |
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
- `doctor` should report the resolved engine PATH, since the app now reads the
  login environment once with a 5s deadline and falls back if it times out —
  a fallback nobody can currently see
- Capture the About panel and the menu bar item in the screenshot set, so the
  docs show them without anyone having to open the app
- Sheets render flat against the parent window, with no material and no edge to
  separate them. Tried and abandoned on 2026-09-08: glass surfaces, a cleared
  sheet window and a `SheetChrome` representable each changed nothing visible.
  Not filed, because there is no next step to file — it wants a fresh read by
  someone who knows where macOS actually decides this, not another attempt from
  the same direction
