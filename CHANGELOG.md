# Changelog

Notable changes, newest first. See [docs/VERSIONING.md](docs/VERSIONING.md) for
what the numbers mean.

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
