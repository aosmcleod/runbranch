#!/usr/bin/env bash
#
# Build the whole graphic set from two SVG sources. No design tool in the loop
# and nothing binary in git except what this produces.
#
#   assets/icon.svg       the app tile, glyph inset within the icon grid
#   assets/icon-dark.svg  the same drawing for the dark appearance
#   assets/mark.svg       the glyph alone, transparent, filling its bounds
#
# Outputs:
#   build/Icons.xcassets  hand-written asset catalogue (intermediate)
#   <app>/Contents/Resources/Assets.car + AppIcon.icns   via actool
#   docs/img/*.png        for the README, the GitHub social preview, docs
#
# Needs only sips, iconutil and actool, all of which ship with macOS and the
# Xcode command line tools.
#
# On layered icons: macOS 26 prefers a .icon authored in Icon Composer, from
# which the system derives its own specular highlight, blur and shadow. That
# format is undocumented and GUI-only, so this ships a conventional asset
# catalogue instead — which does carry real appearance variants, but not the
# system's Liquid Glass lighting. The artwork therefore keeps a little depth of
# its own rather than being drawn flat and looking flat.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-}"                       # an .app bundle, or empty for docs only
BUILD="$REPO/build"
SET="$BUILD/Icons.xcassets/AppIcon.appiconset"

command -v sips >/dev/null 2>&1 || { echo "sips is missing" >&2; exit 1; }

echo "==> icons"
rm -rf "$BUILD"
mkdir -p "$SET" "$REPO/docs/img"

render() {  # svg, px, out
  sips -s format png "$1" --out "$BUILD/full.png" >/dev/null
  sips -z "$2" "$2" "$BUILD/full.png" --out "$3" >/dev/null
}

# --- app icon, light and dark ----------------------------------------------
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  size="${spec%%:*}"; scale="${spec#*:}"; px=$((size * scale))
  render "$REPO/assets/icon.svg"      "$px" "$SET/light-${size}x${size}@${scale}x.png"
  render "$REPO/assets/icon-dark.svg" "$px" "$SET/dark-${size}x${size}@${scale}x.png"
done

python3 - "$SET" <<'PY'
import json, sys
d = sys.argv[1]
images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        base = {"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x"}
        images.append({**base, "filename": f"light-{size}x{size}@{scale}x.png"})
        images.append({**base, "filename": f"dark-{size}x{size}@{scale}x.png",
                       "appearances": [{"appearance": "luminosity", "value": "dark"}]})
json.dump({"images": images, "info": {"author": "runbranch", "version": 1}},
          open(f"{d}/Contents.json", "w"), indent=2)
PY
echo "    catalogue written"

if [ -n "$DEST" ]; then
  [ -d "$DEST" ] || { echo "no app bundle at $DEST" >&2; exit 1; }
  mkdir -p "$DEST/Contents/Resources"
  xcrun actool "$BUILD/Icons.xcassets" \
    --compile "$DEST/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD/icon.plist" >/dev/null
  echo "    Assets.car + AppIcon.icns compiled into the bundle"
fi

# --- the mark, for everywhere that is not the Dock -------------------------
for px in 256 512 1024; do
  render "$REPO/assets/mark.svg" "$px" "$REPO/docs/img/mark-$px.png"
done
render "$REPO/assets/icon.svg" 512 "$REPO/docs/img/icon-512.png"
echo "    docs/img written"

rm -f "$BUILD/full.png"
echo "    done"
