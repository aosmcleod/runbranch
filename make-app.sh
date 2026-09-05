#!/usr/bin/env bash
#
# Build "Project Launcher.app" -- the front end, compiled from
# app/ProjectLauncher.swift. All the actual work stays in project-launcher.sh;
# the app runs it as a subprocess and streams it into a window.
#
# Needs only the Xcode command line tools (swiftc) plus sips and iconutil,
# which ship with macOS. No packages, no SPM manifest, no Xcode project.
#
#   ./make-app.sh                  build next to this script
#   ./make-app.sh /Applications    build into /Applications instead

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$REPO/project-launcher.sh"
SOURCE="$REPO/app/ProjectLauncher.swift"
DEST="${1:-$REPO}"
APP="$DEST/Project Launcher.app"

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
# sips reads SVG on macOS 13+, so the source of truth stays a diffable file
# rather than a checked-in binary.
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
BASE="$TMP/base.png"
sips -s format png "$REPO/assets/icon.svg" --out "$BASE" >/dev/null

for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
            128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
            512:512x512 1024:512x512@2x; do
  px="${spec%%:*}"; name="${spec#*:}"
  sips -z "$px" "$px" "$BASE" --out "$ICONSET/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"
echo "    icon built"

# --- binary ---------------------------------------------------------------
swiftc -parse-as-library -O "$SOURCE" -o "$APP/Contents/MacOS/ProjectLauncher"
echo "    binary built"

# --- Info.plist -----------------------------------------------------------
# FLScriptPath is how the app finds its engine. Baked at build time; re-run
# make-app.sh if the repo moves.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Project Launcher</string>
  <key>CFBundleDisplayName</key>       <string>Project Launcher</string>
  <key>CFBundleIdentifier</key>        <string>local.project.launcher</string>
  <key>CFBundleVersion</key>           <string>3.0</string>
  <key>CFBundleShortVersionString</key><string>3.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>ProjectLauncher</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
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
