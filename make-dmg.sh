#!/usr/bin/env bash
#
# Package the built app as a disk image someone else can install.
#
#   ./make-dmg.sh
#
# Produces dist/Runbranch-<version>.dmg containing the app and a drop target
# for /Applications. The version is read out of the built bundle rather than
# repeated here, so there is still one place it is declared.
#
# No custom background art or icon layout. Both need the disk image to be
# mounted read-write and then arranged by scripting Finder, which requires
# Automation permission for whichever terminal is running this — a permission
# that prompts, can be denied, and leaves the script hanging on a dialog. A
# release script that can stall on a permission dialog is worse than a plain
# window, so this stays plain.
#
# The app is signed with a self-signed local identity, not a Developer ID, so
# Gatekeeper will refuse to open it on a machine that did not build it. That is
# not something packaging can fix — it needs notarisation, which needs a paid
# certificate. Until then the disk image carries a short note saying how to
# open it, because without one the app looks broken rather than unsigned.

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$REPO/Runbranch.app"
DIST="$REPO/dist"

step() { printf '==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '%s\n' "$1" >&2; [ -n "${2:-}" ] && printf '  %s\n' "$2" >&2; exit 1; }

command -v hdiutil >/dev/null 2>&1 || die "hdiutil is missing, which should not be possible on macOS"

[ -d "$APP" ] || die "no built app at $APP" "./make-app.sh"

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)" \
  || die "could not read the version out of $PLIST"
[ -n "$VERSION" ] || die "the built app declares no CFBundleShortVersionString"

DMG="$DIST/Runbranch-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

step "staging $VERSION"
# -R rather than -a: a symlink to the built app would package the link.
cp -R "$APP" "$STAGE/Runbranch.app"
ln -s /Applications "$STAGE/Applications"
info "Runbranch.app and a drop target for /Applications"

cat > "$STAGE/Read me first.txt" <<NOTE
Runbranch $VERSION

To install: drag Runbranch to Applications.

The first launch will be refused, with macOS saying it cannot check the app for
malicious software. That is because this build is signed with a self-signed
certificate rather than a paid Apple Developer ID, which is a statement about
the certificate and not about the app.

To open it anyway:

  1. Try to open Runbranch. Let macOS refuse.
  2. Open System Settings > Privacy & Security.
  3. Scroll to Security. There will be a line about Runbranch being blocked,
     with an "Open Anyway" button. Press it.

That is needed once. Afterwards it opens normally.

If you would rather not do that, build it yourself instead — it takes about
five seconds and needs only the Xcode command line tools:

  git clone https://github.com/aosmcleod/runbranch
  cd runbranch && ./make-app.sh

Source, licence (GPL-3.0) and documentation:
https://github.com/aosmcleod/runbranch
NOTE

step "building the image"
mkdir -p "$DIST"
rm -f "$DMG"
# HFS+ rather than APFS: an APFS image will not mount on macOS 10.12 or older,
# and there is nothing here that needs APFS.
hdiutil create \
  -srcfolder "$STAGE" \
  -volname "Runbranch $VERSION" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"
info "$(cd "$DIST" && du -h "$(basename "$DMG")" | cut -f1) $DMG"

step "checking it"
hdiutil verify -quiet "$DMG" || die "the image did not verify"
info "checksum ok"

# Mount it and look, rather than trusting that the copy above did what it said.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
mounted_ok=1
[ -d "$MOUNT/Runbranch.app" ] || { echo "    the image has no Runbranch.app in it" >&2; mounted_ok=0; }
[ -L "$MOUNT/Applications" ] || { echo "    the image has no /Applications link" >&2; mounted_ok=0; }
if [ -d "$MOUNT/Runbranch.app" ]; then
  codesign --verify --deep --strict "$MOUNT/Runbranch.app" 2>/dev/null \
    && info "signature intact after packaging" \
    || { echo "    the signature did not survive packaging" >&2; mounted_ok=0; }
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$MOUNT/Runbranch.app/Contents/Info.plist" 2>/dev/null || true)"
  [ "$v" = "$VERSION" ] && info "the packaged app says $v" \
    || { echo "    packaged app says [$v], expected [$VERSION]" >&2; mounted_ok=0; }
fi
hdiutil detach "$MOUNT" -quiet || true
rmdir "$MOUNT" 2>/dev/null || true
[ "$mounted_ok" = 1 ] || die "the image built but did not check out"

printf '\nUpload it:\n  gh release upload v%s %s\n' "$VERSION" "$DMG"
