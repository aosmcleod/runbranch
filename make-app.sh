#!/usr/bin/env bash
#
# Build "Frankly Launcher.app" -- a minimal bundle whose only job is to be
# dragged to the Dock. The bundle does NOT contain a copy of the launcher: its
# executable calls frankly-launcher.sh where it sits in this repo, so editing
# the script takes effect immediately with no rebuild.
#
# Uses only sips and iconutil, both built into macOS.
#
#   ./make-app.sh            build next to this script
#   ./make-app.sh /Applications   build into /Applications instead

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$REPO/frankly-launcher.sh"
DEST="${1:-$REPO}"
APP="$DEST/Frankly Launcher.app"

[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }

echo "==> building $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- icon -----------------------------------------------------------------
# sips reads SVG on macOS 13+, so the source of truth stays a diffable file
# rather than a checked-in binary.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
BASE="$(dirname "$ICONSET")/base.png"
sips -s format png "$REPO/assets/icon.svg" --out "$BASE" >/dev/null

for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
            128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
            512:512x512 1024:512x512@2x; do
  px="${spec%%:*}"; name="${spec#*:}"
  sips -z "$px" "$px" "$BASE" --out "$ICONSET/icon_$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Also keep a PNG: `display dialog` can wear a custom icon, and without one
# every prompt shows the generic script icon, which reads as an error rather
# than as this app asking a question. frankly-launcher.sh looks for it here.
sips -z 512 512 "$BASE" --out "$APP/Contents/Resources/AppIcon.png" >/dev/null

rm -rf "$(dirname "$ICONSET")"
echo "    icon built"

# --- Info.plist -----------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Frankly Launcher</string>
  <key>CFBundleDisplayName</key>       <string>Frankly Launcher</string>
  <key>CFBundleIdentifier</key>        <string>local.frankly.launcher</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>FranklyLauncher</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# --- executable -----------------------------------------------------------
# The script path is baked in at build time. Re-run make-app.sh if the repo
# ever moves; the error below says exactly that.
cat > "$APP/Contents/MacOS/FranklyLauncher" <<LAUNCHER
#!/bin/bash
#
# An app launched from the Dock inherits launchd's PATH -- /usr/bin:/bin:
# /usr/sbin:/sbin -- not the one your shell builds. Under it docker
# (/usr/local/bin), pnpm and gh (/opt/homebrew/bin) and node (fnm) are all
# invisible, and the launcher reports them missing while they sit right there.
#
# So run the launcher through a LOGIN + INTERACTIVE zsh: -l reads the login
# files and -i reads ~/.zshrc, which is where fnm's shell hook lives. PATH then
# matches your terminal exactly. Only environment variables cross into the
# script's own bash process, so shell functions defined in ~/.zshrc (the git
# wrapper, for one) cannot alter how the launcher behaves.
SCRIPT="$SCRIPT"
if [ ! -x "\$SCRIPT" ]; then
  osascript -e 'display alert "Frankly Launcher" message "The launcher script is missing from:

$SCRIPT

The repo has moved or been deleted. Re-run make-app.sh from wherever it lives now." as critical buttons {"OK"}'
  exit 1
fi
if [ -x /bin/zsh ]; then
  # zsh -c sets \$0 from the first operand, so the script path and every
  # argument are passed as real positional parameters -- no quoting of the
  # path into a command string, and arguments survive.
  exec /bin/zsh -lic 'exec "\$0" "\$@"' "\$SCRIPT" "\$@" </dev/null
fi
exec "\$SCRIPT" "\$@"
LAUNCHER
chmod +x "$APP/Contents/MacOS/FranklyLauncher"

# Nudge Finder/Dock to pick up the new icon rather than a cached generic one.
touch "$APP"
echo "    done"
echo
echo "Drag this to the Dock:"
echo "  $APP"
