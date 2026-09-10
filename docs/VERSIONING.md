# Versioning

Runbranch uses [semantic versioning](https://semver.org), read from the point
of view of someone whose projects it runs.

| Part | Changes when |
|---|---|
| **Major** | A config that worked stops working, or a command changes meaning. Anything that makes someone edit a `.conf` or a script before they can carry on |
| **Minor** | New capability, no action required. A new config key with a sane default, a new subcommand, something the app can now do |
| **Patch** | A fix, a message, a document. Nothing new to learn |

The version lives in one place — `CFBundleShortVersionString` and
`CFBundleVersion` in `make-app.sh` — and is what About shows. `make-dmg.sh`
reads it back out of the built bundle rather than repeating it, so the file
name and the About panel cannot disagree.

## What counts as breaking

The contract is the config format and the CLI, because those are what people
build habits and scripts around:

- Removing or renaming a config key, or changing what one does
- Removing a subcommand, or changing its arguments or output shape
- Changing where state lives, such that an existing run is orphaned
- Requiring a newer macOS

The SwiftUI layer is not part of the contract. The window can be rearranged in
a minor release.

## Releasing

1. Bump both version keys in `make-app.sh`
2. `./make-app.sh --release` — builds and signs. Without `--release` you get a
   development build, and `make-dmg.sh` will refuse it at step 7 rather than
   package it
3. `./tools/lint.sh && ./tests/engine.sh && ./tests/ui.sh` — all green.
   If `ui.sh` reports SKIPPED, the render was not checked: grant this build
   Screen Recording and run it again before releasing
4. `./tools/screenshot.sh` if the window changed, so the README matches the
   app. It refuses to run without a 2x display attached, because the docs set
   is 2x and a 1x capture looks soft beside the rest — open the laptop lid if
   it stops
5. Update `CHANGELOG.md`: what changed, and for a major, what to do about it
6. Commit as `Release vX.Y.Z`, tag `vX.Y.Z`, push both
7. `./make-dmg.sh` — packages, verifies, and mounts the image to check the
   signature survived
8. `gh release create vX.Y.Z --notes-file …` and upload the disk image, because
   a release with no artifact is a tag

A release nobody can install is not a release, which is why the disk image is a
step rather than an afterthought.

## Naming a release

The GitHub release is titled `Runbranch X.Y.Z`. Nothing else — no theme, no
adjective. A title that describes one release's circumstances ("installable")
reads as a permanent property of the software rather than a fact about that
build, and it is wrong by the next release.

Every listed release has a disk image attached. A release without one is a tag
wearing a release's clothes, and the honest thing is to leave it as a tag.
`v1.0.0` is exactly that: the tag is real history and the CHANGELOG describes
it, but it was published with nothing to download, so it has no release page.

## Pre-1.0 and 1.0

Everything before 1.0.0 was built in one long stretch by one person and never
published. 1.0.0 is the first version anyone else could install, which is what
makes it 1.0.0 — not a judgement that it is finished. `docs/ROADMAP.md` is
candid about what it is not.
