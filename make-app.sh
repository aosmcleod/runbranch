#!/usr/bin/env bash
#
# Build "Runbranch.app" -- the front end, compiled from
# app/RunBranch.swift. All the actual work stays in runbranch.sh;
# the app runs it as a subprocess and streams it into a window.
#
# Needs only the Xcode command line tools (swiftc) plus sips and iconutil,
# which ship with macOS. No packages, no SPM manifest, no Xcode project.
#
#   ./make-app.sh                  build next to this script
#   ./make-app.sh /Applications    build into /Applications instead

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$REPO/runbranch.sh"
SOURCE="$REPO/app/RunBranch.swift"
DEST="${1:-$REPO}"
APP="$DEST/Runbranch.app"

[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }
command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc is not on PATH. Install the Xcode command line tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
}

echo "==> building $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- icon -----------------------------------------------------------------
# See make-icons.sh: one PNG source, cleaned and optically centred, tiles
# rendered through WebKit, appearance variants via actool. No GUI, no design tool.
"$REPO/make-icons.sh" "$APP"

# The bare glyph on transparency, for in-app use. Inside the window the rounded
# app tile is redundant and its light backing sits badly on a dark splash.
cp "$REPO/docs/img/mark-256.png" "$APP/Contents/Resources/Mark.png"

# Menu bar template glyph, from the seamed vector: the two petals and the lens
# where they cross are separate paths, so the silhouette reads as two shapes
# rather than one blob. The solid version is also here
# (assets/mark-silhouette.svg) — swap the argument to compare.
swift "$REPO/tools/menubar-glyph.swift" "$REPO/assets/mark-template.svg" \
  "$APP/Contents/Resources"

# --- binary ---------------------------------------------------------------
swiftc -parse-as-library -O "$SOURCE" -o "$APP/Contents/MacOS/RunBranch"
echo "    binary built"

# --- Info.plist -----------------------------------------------------------
# FLScriptPath is how the app finds its engine. Baked at build time; re-run
# make-app.sh if the repo moves.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Runbranch</string>
  <key>CFBundleDisplayName</key>       <string>Runbranch</string>
  <key>CFBundleIdentifier</key>        <string>dev.runbranch.app</string>
  <key>CFBundleVersion</key>           <string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
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
  <key>FLScriptPath</key>              <string>$SCRIPT</string>
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
