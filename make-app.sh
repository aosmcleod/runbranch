#!/usr/bin/env bash
#
# Build "Runbranch.app" -- the front end, compiled from
# the Swift sources in app/. All the actual work stays in runbranch.sh;
# the app runs it as a subprocess and streams it into a window.
#
# Needs only the Xcode command line tools (swiftc) plus sips and iconutil,
# which ship with macOS. No packages, no SPM manifest, no Xcode project.
#
# Builds are development builds unless you say otherwise. A development build
# carries the mark with its colours inverted and says so in About, because the
# copy in this folder and the copy in /Applications are otherwise identical in
# the Dock and the Cmd-Tab strip. Shipping is the deliberate act, so it is the
# one that needs a word:
#
#   ./make-app.sh                  a development build, next to this script
#   ./make-app.sh --release        the shipping build — what make-dmg.sh wants
#   ./make-app.sh /Applications    a development build, installed
#
# make-dmg.sh and tools/screenshot.sh both refuse a development build, so
# forgetting --release cannot put one in a disk image or in the documentation.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$REPO/runbranch.sh"
SOURCE="$REPO/app"
CHANNEL="development"
if [ "${1:-}" = "--release" ]; then CHANNEL="release"; shift; fi
DEST="${1:-$REPO}"
APP="$DEST/Runbranch.app"

[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
[ -d "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }
command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc is not on PATH. Install the Xcode command line tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
}

echo "==> building $APP ($CHANNEL)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- icon -----------------------------------------------------------------
# See make-icons.sh: one PNG source, cleaned and optically centred, tiles
# rendered through WebKit, appearance variants via actool. No GUI, no design tool.
if [ "$CHANNEL" = "development" ]; then
  "$REPO/make-icons.sh" --dev "$APP"
else
  "$REPO/make-icons.sh" "$APP"
fi

# The bare glyph on transparency, for in-app use. Inside the window the rounded
# app tile is redundant and its light backing sits badly on a dark splash.
if [ "$CHANNEL" = "development" ]; then
  cp "$REPO/build/bin/mark-256-dev.png" "$APP/Contents/Resources/Mark.png"
else
  cp "$REPO/docs/img/mark-256.png" "$APP/Contents/Resources/Mark.png"
fi

# The engine, inside the bundle.
#
# The app used to find it through an absolute path written into Info.plist at
# build time, which works on the machine that built it and nowhere else — a
# copy handed to anyone else would launch and find no engine at all. Bundling
# it also means the app under test is the app that ships.
cp "$REPO/runbranch.sh" "$APP/Contents/Resources/runbranch.sh"
chmod +x "$APP/Contents/Resources/runbranch.sh"

# The changelog, as data, for the "what's new" sheet.
#
# Bundled rather than fetched at runtime: it has to work with no network, and
# it has to work for a build from source, which has no release to read notes
# off. CHANGELOG.md stays the only copy anyone edits.
python3 - "$REPO/CHANGELOG.md" "$APP/Contents/Resources/ReleaseNotes.json" <<'NOTES'
import json, re, sys

source, dest = sys.argv[1], sys.argv[2]
entries, version, body = [], None, []

def keep():
    if version:
        entries.append({"version": version, "notes": "\n".join(body).strip()})

for line in open(source):
    m = re.match(r'^##\s+v?(\d+(?:\.\d+)*)\s*$', line.rstrip())
    if m:
        keep()
        version, body = m.group(1), []
        continue
    if version is not None:
        body.append(line.rstrip())
keep()

json.dump(entries, open(dest, "w"), indent=1)
print("    release notes: %d versions" % len(entries))
NOTES

# The script that swaps a downloaded build in for this one. It runs from a copy
# in /tmp rather than from here, because by the time it does its work this
# bundle is what it is deleting.
cp "$REPO/tools/install-update.sh" "$APP/Contents/Resources/install-update.sh"
chmod +x "$APP/Contents/Resources/install-update.sh"

# Menu bar template glyph, from the seamed vector: the two petals and the lens
# where they cross are separate paths, so the silhouette reads as two shapes
# rather than one blob. The solid version is also here
# (assets/mark-silhouette.svg) — swap the argument to compare.
swift "$REPO/tools/menubar-glyph.swift" "$REPO/assets/mark-template.svg" \
  "$APP/Contents/Resources"

# --- binary ---------------------------------------------------------------
swiftc -parse-as-library -O "$SOURCE"/*.swift -o "$APP/Contents/MacOS/RunBranch"
# swiftc does not strip, so the Swift mangled-name table ships — over half the
# binary, and nothing at runtime reads it. -x keeps the dynamically-referenced
# symbols and drops the local ones.
#
# Before codesign, never after: stripping a signed binary invalidates the
# signature, and the Screen Recording grant is tied to it.
strip -x "$APP/Contents/MacOS/RunBranch" 2>/dev/null || \
  echo "    !! strip failed; the binary ships with its symbol table" >&2
echo "    binary built"

# --- Info.plist -----------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Runbranch</string>
  <key>CFBundleDisplayName</key>       <string>Runbranch</string>
  <key>CFBundleIdentifier</key>        <string>dev.runbranch.app</string>
  <key>CFBundleVersion</key>           <string>1.5.0</string>
  <key>CFBundleShortVersionString</key><string>1.5.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>RunBranch</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundleIconName</key>          <string>AppIcon</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- Health checks talk to http://localhost. Without this, App Transport
       Security blocks them and every target sits at "starting" forever, while
       the engine (which uses curl) reports it healthy. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>  <true/>
  </dict>
$(if [ "$CHANNEL" = "development" ]; then cat <<'DEV'
  <!-- Development build. Read by About, by the updater (which does not run
       here — an update would replace the build you are working on with a
       release), by make-dmg.sh and by tools/screenshot.sh, all of which
       refuse rather than quietly do the wrong thing. Absent on a release. -->
  <key>RBBuildChannel</key>            <string>development</string>
DEV
fi)
</dict>
</plist>
PLIST

# Signing identity. An ad-hoc signature (-s -) derives the identity from the
# binary's own hash, so every rebuild looks like a different app to macOS and
# any privacy grant given to the previous build is dropped. That is fine for
# just running the app, but it revokes the Screen Recording permission the
# screenshot pipeline needs, every single time.
#
# So prefer a fixed local certificate when one exists. ./tools/make-signing-identity.sh
# creates it; without it we fall back to ad-hoc and say what that costs.
SIGN_ID="Runbranch Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
    && echo "    signed with $SIGN_ID" \
    || { echo "    !! signing with $SIGN_ID failed, falling back to ad-hoc" >&2
         codesign --force --sign - "$APP" >/dev/null 2>&1 || true; }
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "    signed ad-hoc (screenshots will need re-granting; see tools/make-signing-identity.sh)"
fi

touch "$APP"
echo "    done"
echo
echo "Drag this to the Dock:"
echo "  $APP"
