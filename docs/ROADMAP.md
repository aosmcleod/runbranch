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
| 1.11 | ✅ **Publish it** — public at `aosmcleod/runbranch` under GPL-3.0, and v1.0.1 ships a verified disk image | Every other v1 item was justified by "it is going public". 1.0.0 was a tag with nothing attached, which failed the bar this section sets |
| 1.10 | ✅ **Decompose ContentView** — ten files; 20 state properties rather than 31, with five sheets and a title string collapsed into one value | Both bugs behind 1.9 lived in this view's state wiring. A shape that could represent six open sheets at once is where the next one would have |
| 1.9 | ✅ **A UI smoke test** — `tests/ui.sh`, 10 assertions, the last two read the window back through Vision text recognition | The eight state assertions pass with the stale-render bug reintroduced; the two that read the screen fail. That asymmetry is the whole point, and it is why the gap took a second attempt |

### Why 1.9

The engine has 112 assertions. The app had none, and on 2026-09-08 that cost
two real bugs:

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
were in that wiring rather than in logic a unit test would reach.

The first attempt caught the duplicate window and missed the stale render
entirely, because it asked the app what it thought and the app thought
correctly. Closing it needed the pixels: the app photographs its own window
through the capture path the documentation already used, runs text recognition
over it, and reports what came back. That read needs the Screen Recording
grant, so it skips loudly when it cannot look rather than passing.

### Why 1.10

The review found the engine in reasonable shape — one duplicated block, since
removed, and no dead functions. The app was the imbalance: `ContentView` at 918
lines and 31 state properties, inside a single file of 3,591 that had grown
while sitting on this list.

"Nothing here is broken" turned out to be half right. Splitting the file was
mechanical, but two of the state reductions were defects rather than tidying:

- Five sheets and a loose title string could all be raised at once, and a run
  title could exist with no run sheet to put it on. They are one value now, and
  raising one goes through a single function — which is also where the reason
  for care lives: replacing a sheet inside one update leaves SwiftUI presenting
  neither, and the "Run on N" path would have hit exactly that.
- A set was computed on every port sweep and read nowhere, orphaned when the
  port alert icon came out.

The precedent was already in the codebase: the earlier "mixed data while
switching projects" bug was fixed by collapsing six independent properties into
one atomically-swapped `ProjectSnapshot`.

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

Of the follow-ups these opened, the first is fixed: an in-place run now says,
in red, when the checkout has been switched to another branch underneath it.
The servers keep running and keep serving, so what is wrong is the label and
possibly what you believe is running. Still open is
[#14](https://github.com/aosmcleod/runbranch/issues/14) — Vite resolves a
different project root in place than it does in a worktree.

---

## v1.1 — the things you notice on day two

| | Item | Why |
|---|---|---|
| 2.1 | ✅ **Menu bar mode** — Dock, both, or menu bar only; status item with the current run, Stop, and a way back to the window | A demo runs for an hour while you use other apps. The window is not where you want the status |
| 2.13 | ✅ **Keep the ports view current on a timer** — thirty seconds, skipped while the window is occluded or a modal sheet is up | Each read is one `lsof` per declared port plus a `ps` to attribute it. That cost is why it is thirty seconds and not a tight poll — and why measuring disk, which walks node_modules, is deliberately not on it |
| 2.12 | ✅ **Update a run to the branch's latest commit** — the strip says how many commits behind, and an Update button appears only when there is something to catch up on | A worktree is pinned to the commit it was cut at. Refresh only re-reads pull request metadata and was reasonably mistaken for this, so a run could sit on old code looking current. An always-present Update would have made the same confusion |
| 2.2 | [#7](https://github.com/aosmcleod/runbranch/issues/7) **Per-target restart** — restart web without restarting the api | Overmind's best idea. A Next rebuild should not cost a database connection |
| 2.3 | [#8](https://github.com/aosmcleod/runbranch/issues/8) **Notifications** — ready, failed, and "still running after an hour" | The run outlives the window on purpose; it should be able to say so |
| 2.4 | ✅ **Log improvements** — jump to the first error, errors tinted, and it tails from an offset rather than re-reading the file every 1.5s | The viewer worked and did not help you read. The follow and wrap toggles this item asked for were built and then removed: follow is on by default and the tail is where you already are, so the control read as a download button that did nothing, and wrap had no counterpart worth keeping once lines simply wrapped. Copy went with them, since the log is selectable text |
| 2.5 | ✅ **Disk usage in the app** — a Disk sheet with every worktree, what it costs, and `prune-gone` behind a Reclaim menu | Measured when the sheet opens, never on the refresh path: `du -sk` per worktree walks node_modules, at 3.35s against 0.58s for every other engine call put together. "Merged" deliberately stays out of the pruning, since a squash-merge leaves a branch looking unmerged |
| 2.6 | ✅ **Remove a project** — right-click → Remove Project, with a confirmation naming the repository it will not touch; refused while running | Adding is in the app; removing still means deleting a file by hand |
| 2.7 | [#11](https://github.com/aosmcleod/runbranch/issues/11) **Quick Look the diff** — space on a branch shows what changed against the default | Deciding whether to run a branch is the step before running it |
| 2.10 | ✅ **Worktree names can collide** — `worktree_slug` now records the owning ref in a meta file and gives a second, colliding ref a digest suffix | Found by probing, not by hitting it. The per-run *database* name had the same bug and was fixed with it, which is the part that would have corrupted data rather than just confusing the UI |
| 2.11 | ✅ **The app has no way to report an error** — `Engine.failure` routes 11 previously-silent paths to an alert that names the command | Every other error path in this project names the command that fixes it. The app was throwing that away for anything that was not a streamed run |
| 2.9 | ✅ **Port allocation across projects** — `overlaps` and `suggest-offset` in the engine; the Ports sheet lists the clashes with a Move… menu that picks the number; `PORT_OFFSET` editable and documented | Framework defaults collide — three projects here all want 5173. The engine half shipped first and left the user picking the number by hand, in a file, in two places per target, which was the half that made it worth doing. Deliberately not surfaced on the project rows: nothing is wrong until you try to run the second one |

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
