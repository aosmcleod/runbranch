# Changelog

Notable changes, newest first. See [docs/VERSIONING.md](docs/VERSIONING.md) for
what the numbers mean.

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
