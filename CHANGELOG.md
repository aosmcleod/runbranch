# Changelog

Notable changes, newest first. See [docs/VERSIONING.md](docs/VERSIONING.md) for
what the numbers mean.

## 1.5.0

> **Before you install this one, copy your projects out of the app.** In the
> Finder, right-click Runbranch in Applications, Show Package Contents, then
> `Contents/Resources/projects` — put that folder somewhere safe. Installing
> 1.5.0 deletes it, and this release exists because it should never have been
> there. Afterwards, put the `.conf` files in `~/.runbranch/projects` and they
> are safe for good. If you have never added a project through the app, there
> is nothing to save.
>
> This applies to this update only. The step that destroys them lives in the
> version you are running now, not in the one being installed, so 1.5.0 cannot
> prevent it from happening this once — only from ever happening again.

**Your projects survive an update**

Project configuration was written inside the app bundle. Installing a new
version replaces the bundle whole, so the app came back with nothing declared
and offered to onboard you — which is the most confident possible way to say
that your configuration is gone.

This was never specific to the updater. Dragging a new copy from a disk image
over the old one does the same and has since 1.0.0. 1.3.0 only made it
automatic, and 1.3.0 to 1.4.0 was the first update anyone had.

- The app now keeps `.conf` files in `~/.runbranch/projects`, beside the
  per-project state that already survived. Nothing is kept in the bundle
- Running `runbranch.sh` from a checkout is unchanged: `projects/` beside the
  script is committed, with a README and an example in it, and someone who
  cloned the repo put their files there on purpose. `RB_PROJECTS_DIR` still
  wins over both, and `runbranch.sh projects-dir` prints the one in effect
- The installer carries anything still sitting in the old bundle across before
  deleting it, and the engine does the same on launch for an app that was
  replaced by hand. Neither ever overwrites the copy in `~/.runbranch`, because
  that is the one that survived
- The app asks the engine where projects live rather than working it out from
  the path of the script it runs. Deriving it is how it came to be pointing
  inside its own bundle, and that sum cannot live in two places and stay right

## 1.4.0

**Branches say whether they are still alive**

A branch you do not recognise told you its name, its author and its age, and
none of those answer the question you actually have: is this live work, or is
it finished and safe to delete? A list you cannot triage is a list you scroll
past.

- Every row carries how many commits it is **ahead of and behind the default
  branch**, beside the age. Ahead of *origin's* copy, not the local one — a
  checkout whose `main` has not been fetched in a fortnight would report
  everything as behind by nothing, which is worse than saying nothing at all
- A branch with nothing the trunk does not already have is badged **merged**,
  however it got there. Runbranch could only ever say that when a pull request
  said it, and plenty of work lands without one: a squash rewrites the commits,
  a rebase moves them, and some branches are merged by hand and never opened as
  a pull request at all. The commit graph sees all four
- **Show merged** now hides both readings. It was honest about the pull request
  record and silently kept the rest
- The **default** badge is blue rather than teal. Teal was a workaround for a
  badge disappearing into a selected row's fill; the badge now draws white on
  the fill instead, so the colour can be the one a default branch wears
  everywhere else

The counts come from one `git for-each-ref` walk rather than a `rev-list` per
branch — 0.4s for a repo with three hundred remote branches. The atom needs git
2.41, and an unknown atom is fatal to `for-each-ref` rather than ignorable, so
it is probed once: a git one release too old loses the column and not the
branch list.

**Development builds are visibly development builds**

The copy in your working folder and the copy in `/Applications` were the same
icon, the same name and the same Cmd-Tab entry, and telling them apart meant
reading a window title.

- A build is a development build unless you ask for a release. Its mark comes
  out colour-inverted, About carries a badge, and it does not check for updates
- That last one is not decoration. The updater added in 1.3.0 would have
  offered to replace a build being worked on with whatever was last tagged, and
  **Update** is one click
- `make-dmg.sh` refuses to package one and `tools/screenshot.sh` refuses to
  capture one, because the documentation depicts the app people install

**Fixed**

- Both of those scripts told you to build a release and then left it sitting in
  the working folder, which put back the confusion the build channel exists to
  prevent. They now restore the development build when they finish — on success
  only, since a failed capture is retried immediately and a failed packaging is
  the one you want to inspect

## 1.3.0

**Runbranch updates itself**

Nobody returns to a releases page, so 1.2.0 is what most people who installed
it are still running. The app looks for a newer release once when it opens, and
installs the one it finds.

- A newer release raises a sheet with its notes, and **Update** does the rest:
  download, checksum, install, restart. There is no step where you are handed a
  disk image and left to it
- The first launch after an update opens on what changed — every version
  between the one you had and the one you have, not only the newest, so
  skipping two releases cannot hide one of them
- **Check for Updates…** sits beside About, for when you would rather ask
- The check is on by default and turned off from either the update sheet or the
  ••• menu. It is one unauthenticated request to the GitHub releases API at
  launch and nothing else

An update does not repeat the Open Anyway dance. The quarantine flag that
triggers it is attached by whatever downloads the file, and browsers opt into
that where an app fetching its own update does not — so the version Runbranch
installs opens normally. You do that once, on first install, and never again.

Deliberately not Sparkle, which is what the roadmap asked for. Sparkle is built
around a Developer ID: its own documentation says its EdDSA signing is not a
substitute for one, and an ad-hoc or self-signed build runs into library
validation loading the framework at all. Both answers in its docs are "sign
with a Developer ID", which is the thing this project does not have — so it
would have added a framework, an XPC service and a signing key without solving
the problem. See [docs/ROADMAP.md](docs/ROADMAP.md).

## 1.2.0

**Two projects that want the same port**

Framework defaults collide — three projects here all want 5173 and two want
3000 — so they cannot run at the same time. The engine could already shift a
project's whole port set and rewrite `{port}` in its commands. Finding out and
acting on it is what was missing.

- The **Ports** sheet lists the clashes and offers a **Move…** menu that picks
  the number. Which project moves is a real choice, so it asks — one of them is
  usually the one you think of as owning the port
- `runbranch.sh overlaps` reports them machine-readably; `doctor` only ever said
  it in prose
- `runbranch.sh suggest-offset <project>` computes the smallest shift that frees
  every port the project declares at once, accounting for whatever is already
  listening — including a dev server Runbranch did not start
- `PORT_OFFSET` is editable in the project sheet, with the effective ports
  spelled out beneath it, and documented in `docs/config.md` for the first time

**Fixed**

- Overlap detection compared *declared* ports, so a project you had already
  shifted still reported as clashing and the fix looked like it had not worked
- The self-test could hang instead of reporting: it awaited the screen-capture
  API unbounded, and a wedged capture service never returns. Its watchdog also
  fired at exactly the duration the test had grown into, and exited without
  writing anything, so a timeout was indistinguishable from a crash
- A failed screenshot capture deleted the image it could not replace. That is
  how five README screenshots went missing between 1.1.0 being tagged and being
  released
- The screenshot pipeline refuses to run without a 2x display attached, rather
  than quietly producing images at half the resolution of the rest of the set

**Removed**

- Four dead properties and three stray `@AppStorage` keys from the project
  sheet — copy-paste residue, and the `@AppStorage` ones were binding the
  sidebar's persisted state from an unrelated view

## 1.1.0

**Runs tell you more about themselves**

- A run says how many commits its branch has gained since the worktree was cut,
  and an **Update** button appears to catch it up. A worktree is pinned to one
  commit, so a run could sit on old code looking current — Refresh only ever
  re-read pull request metadata
- An in-place run says, in red, when the checkout has been switched to another
  branch underneath it. The servers keep running and keep serving, so what is
  wrong is the label and possibly what you believe is running
- A **Disk** sheet: every worktree, what it costs, and a way to reclaim the ones
  whose branch no longer exists. Gone, never merged — a squash-merge leaves a
  branch looking unmerged, so that heuristic would delete work
- The ports view refreshes on its own every thirty seconds, so a server started
  while the window sits idle is noticed

**The log viewer helps you read**

- Follow, wrap, and jump to the first error, with errors tinted so the jump
  lands somewhere visible. Follow and wrap persist between runs

**Faster**

- The refresh after every operation: **4,113ms → 580ms**. Measuring disk usage
  meant `du -sk` per worktree, and a worktree holds `node_modules` — 3.3s of it,
  for a number shown nowhere but the disk sheet. It is measured when that sheet
  opens now
- `ports`: **330ms → 199ms**. One `lsof` for every listener rather than one per
  port. The free-port search was spawning one per offset probed, up to 200
- The log viewer tails from an offset instead of re-reading the whole file every
  1.5 seconds: **133.9ms → 0.1ms per tick on a 16 MB log**, and a tick now costs
  what arrived rather than what exists. Retained lines are capped, so a long run
  cannot quietly take 36 MB of memory

**Smaller**

- The download is **4.4 MB → 2.8 MB**. The binary was 61% Swift symbol table,
  which nothing reads at runtime, and the icon source folder was being shipped
  beside its own compiled form

**Fixed**

- The log viewer showed "0 lines" over a log with plenty in it, if it was opened
  before the run state had loaded
- The disk summary said "1 worktrees" and "Zero KB not in use"

## 1.0.1

**A release you can install**

- `make-dmg.sh` packages the app as a verified disk image and checks the
  signature survived, so the release has something in it. 1.0.0 was a tag
- The disk image says how to get past Gatekeeper, since a self-signed build is
  refused on a machine that did not build it and otherwise just looks broken

**Fixed**

- The default-branch badge was tinted with the accent colour, which is what
  fills a selected row, so it disappeared when selected

**Under it**

- The app's single 3,591-line source is now ten files, and the main view holds
  20 pieces of state rather than 31. Five sheets and a loose title string
  became one value, because only one sheet can be up at a time and the old
  shape could represent six at once
- A set computed on every port sweep and read nowhere is gone. It lost its only
  consumer when the port alert icon came out
- The app smoke test reads its own window through Vision text recognition, so a
  stale render fails the suite. It was written for a bug where the app thought
  correctly and drew something else, and until now it could not see that

## 1.0.0

First published version. Built over several weeks before this point; the
history is in the repository rather than summarised here.

**The tool**

- Runs any branch of any local project on a real port, from a throwaway git
  worktree, without touching your checkout — no `checkout`, no `stash`, ever
- Or in place, in the checkout itself, for the branch you are working on, so
  uncommitted work is live
- Copies gitignored config into the worktree, installs dependencies, brings up
  compose services, migrates and seeds, then starts the servers and waits until
  they answer
- A database per run, created and migrated from scratch, so two branches with
  divergent migrations do not share one. Postgres only
- Branches listed with their pull request state, author and title, remote
  branches with open pull requests included
- Reclaims ports, processes and state left behind by a crash, a sleep or a
  force quit
- Says what else is on a port and whose it is, including servers it did not
  start, and offers to move the run, stop the holder, or wait
- Reports worktree disk use and what is reclaimable

**The app**

- Native macOS, SwiftUI, built against macOS 26
- Every config key editable in the app; projects added by scanning a folder
- Sidebar grouped into running, favourites and the rest, collapsible
- Dock, menu bar, or menu bar only
- Screenshots and an About panel generated from the repository's own tooling

Licensed **GPL-3.0**: free to use, change and redistribute, including
commercially, provided anything built on it ships its source under the same
terms.

**Known limits** are listed in the README, and everything intended but not yet
built is in [docs/ROADMAP.md](docs/ROADMAP.md).
