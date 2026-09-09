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
2. `./make-app.sh` — builds and signs
3. `./tools/lint.sh && ./tests/engine.sh && ./tests/ui.sh` — all green.
   If `ui.sh` reports SKIPPED, the render was not checked: grant this build
   Screen Recording and run it again before releasing
4. `./tools/screenshot.sh` if the window changed, so the README matches the app
5. Update `CHANGELOG.md`: what changed, and for a major, what to do about it
6. Commit as `Release vX.Y.Z`, tag `vX.Y.Z`, push both
7. `./make-dmg.sh` — packages, verifies, and mounts the image to check the
   signature survived
8. `gh release create vX.Y.Z --notes-file …` and upload the disk image, because
   a release with no artifact is a tag

A release nobody can install is not a release, which is why the disk image is a
step rather than an afterthought.

## Pre-1.0 and 1.0

Everything before 1.0.0 was built in one long stretch by one person and never
published. 1.0.0 is the first version anyone else could install, which is what
makes it 1.0.0 — not a judgement that it is finished. `docs/ROADMAP.md` is
candid about what it is not.
