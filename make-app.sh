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
  <key>CFBundleVersion</key>           <string>3.0</string>
  <key>CFBundleShortVersionString</key><string>3.0</string>
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

# An ad-hoc signature is enough for a local build, and it keeps the bundle
# identity stable so macOS does not re-prompt for permissions on every rebuild.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

touch "$APP"
echo "    done"
echo
echo "Drag this to the Dock:"
echo "  $APP"
