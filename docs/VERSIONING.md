# Versioning

Runbranch uses [semantic versioning](https://semver.org), read from the point
of view of someone whose projects it runs.

| Part | Changes when |
|---|---|
| **Major** | A config that worked stops working, or a command changes meaning. Anything that makes someone edit a `.conf` or a script before they can carry on |
| **Minor** | New capability, no action required. A new config key with a sane default, a new subcommand, something the app can now do |
| **Patch** | A fix, a message, a document. Nothing new to learn |

The version lives in one place — `CFBundleShortVersionString` and
`CFBundleVersion` in `make-app.sh` — and is what About shows, on both
platforms. `make-dmg.sh` reads it back out of the built bundle, and
`windows/make-app.ps1` reads it out of `make-app.sh`, rather than either
repeating it, so the file names, the About panels and the two platforms cannot
disagree.

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

A release is one version, one tag and one GitHub release, carrying a download
for each platform it ships on: `Runbranch-X.Y.Z.dmg` for the Mac and
`Runbranch-X.Y.Z-windows-x64.zip` for Windows. Each app's updater looks for its
own file by exactly that name, and treats a release without one as nothing to
offer — so the names are the contract, not a convention.

1. Bump both version keys in `make-app.sh`. That is the only place; the
   Windows build reads it from there
2. `./make-app.sh --release` — builds and signs. Without `--release` you get a
   development build, and `make-dmg.sh` will refuse it at step 8 rather than
   package it
3. `./tools/lint.sh && ./tests/engine.sh && ./tests/ui.sh` — all green.
   If `ui.sh` reports SKIPPED, the render was not checked: grant this build
   Screen Recording and run it again before releasing. The `test` workflow
   covers the engine suite and the build on Windows; it should be green on
   the commit you are about to tag
4. `./tools/screenshot.sh` if the window changed, so the README matches the
   app. It refuses to run without a 2x display attached, because the docs set
   is 2x and a 1x capture looks soft beside the rest — open the laptop lid if
   it stops
5. Update `CHANGELOG.md`: what changed, and for a major, what to do about it.
   Both apps bundle it for "What's new", so it is written once for both
6. Commit as `Release vX.Y.Z`, tag `vX.Y.Z`, push both
7. `gh release create vX.Y.Z --title "Runbranch X.Y.Z" --notes-file …`.
   Publishing starts the `release` workflow, which builds the Windows zip from
   the tagged commit and attaches it. It fails, loudly and before building,
   if the tag and the version in `make-app.sh` disagree — the mistake of
   tagging before bumping, which would otherwise attach a zip no updater looks
   for
8. `./make-dmg.sh` — packages, verifies, and mounts the image to check the
   signature survived. Then `gh release upload vX.Y.Z dist/Runbranch-X.Y.Z.dmg`,
   which it prints
9. Check the release page shows both files before telling anyone

The Mac image is built by hand and the Windows zip is not, because of where
the signing lives. The Mac build is signed with a self-signed identity that
exists in one Mac's keychain (`tools/make-signing-identity.sh`). CI could build
and package an ad-hoc-signed app that passes every check `make-dmg.sh` makes,
but it would not be the app every earlier release shipped, and exporting the
identity into repository secrets to fix that is a worse trade than one local
step. The Windows build has no signing yet, so there is nothing to keep off a
runner, and a clean runner building the tagged commit is a better witness than
whichever machine happens to be at hand.

### One platform only

A release can ship for one platform and catch the other up later. Each app
treats a newer release without its own download as nothing to install: silent
on launch, and said plainly when someone checks by hand ("Runbranch X.Y.Z is
out for Windows"), rather than reported as a failure.

- **Windows only:** publish the release and skip step 8. The Mac download can
  be added to the same release later, once it is ready
- **Mac only:** the workflow runs on publish regardless. Let it attach the
  zip, or, if the Windows build is what is not ready, delete the zip from the
  release and say why in the notes
- **Rebuilding or backfilling a download:** run the `release` workflow by hand
  (Actions → release → Run workflow) with the tag and `windows`. It replaces
  the zip on that release. `mac` and `both` do not build a disk image; the
  `mac` part prints the local commands for that tag and whether the image is
  already attached

A later release supersedes this one on both platforms, so a Mac user who never
got X.Y.Z is offered X.Y.(Z+1) directly. Nothing has to be backfilled for the
updater's sake — only for anyone reading the release page.

A release nobody can install is not a release, which is why the downloads are
steps rather than an afterthought.

## Naming a release

The GitHub release is titled `Runbranch X.Y.Z`. Nothing else — no theme, no
adjective. A title that describes one release's circumstances ("installable")
reads as a permanent property of the software rather than a fact about that
build, and it is wrong by the next release.

Every listed release has at least one platform's download attached — the disk
image, the Windows zip, or both. A release with neither is a tag wearing a
release's clothes, and the honest thing is to leave it as a tag.
`v1.0.0` is exactly that: the tag is real history and the CHANGELOG describes
it, but it was published with nothing to download, so it has no release page.

## Pre-1.0 and 1.0

Everything before 1.0.0 was built in one long stretch by one person and never
published. 1.0.0 is the first version anyone else could install, which is what
makes it 1.0.0 — not a judgement that it is finished. `docs/ROADMAP.md` is
candid about what it is not.
