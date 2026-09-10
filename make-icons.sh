#!/usr/bin/env bash
#
# Build the icon and the documentation images from one source PNG.
#
# macOS 26 does not want a bitmap per appearance. It wants a `.icon` bundle:
# a manifest plus layer images, from which the SYSTEM derives Default, Dark,
# Clear and Tinted, and applies its own lighting, specular highlight and
# shadow. An asset catalogue with light/dark bitmaps is the older mechanism and
# is largely ignored for the Dock icon, which is why the icon looked hardwired
# to one appearance.
#
# The format turns out to be plainly hand-authorable — icon.json plus an
# Assets/ folder — so no GUI is needed. Consequences worth knowing:
#
#   * the artwork must NOT carry its own background, gradient or drop shadow.
#     The system draws the tile and lights it; baking our own gives the
#     doubled-lighting look.
#   * actool compiles the .icon into Assets.car, and also emits an AppIcon.icns
#     so older systems still get an icon.
#
# From the source PNG this also fixes two things in it: a thin matte fringe of
# strongly-coloured near-transparent pixels, and uneven padding. The fringe
# matters beyond tidiness — it sits outside the real artwork, so it drags the
# bounding box outward and takes the centring with it.
#
# A development build gets the same mark with its colours inverted, so the copy
# in the dev folder is not mistakable for the one in /Applications at a glance
# in the Dock. It comes out of the same SVG through the same renderer — a
# second drawing would be a second thing to keep in step, which is the problem
# the single master exists to prevent.
#
#   ./make-icons.sh                 documentation images only
#   ./make-icons.sh <App.app>       and compile the icon into that bundle
#   ./make-icons.sh --dev <App.app> with the inverted mark

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV=""
if [ "${1:-}" = "--dev" ]; then DEV=1; shift; fi
DEST="${1:-}"
BUILD="$REPO/build"
BIN="$BUILD/bin"
ICON="$REPO/assets/AppIcon.icon"
# The vector master, rendered to a raster the rest of this can trim and inset.
#
# There used to be a PNG source alongside the SVG, and the two disagreed: the
# SVG's overlap read blue-violet where the PNG's was magenta, because Figma's
# export had dropped a mix-blend-mode. One master means that cannot recur.
#
# Rendered with WebKit rather than NSImage or sips, neither of which honours
# mix-blend-mode — they would silently reproduce the very bug this replaces.
MASTER="$REPO/assets/mark.svg"
SRC="$BIN/mark-master.png"
# The icon's source raster. A release build takes the master as drawn; a
# development build takes the inverted render. The documentation images and
# assets/mark.png below always come from the master either way — they are
# committed files describing the shipping app, and a dev build has no business
# rewriting them.
ICON_SRC="$SRC"

ALPHA_CUTOFF=0.22     # below this, a pixel is fringe rather than soft edge
ICON_FRACTION=0.72    # the glyph inside the system's tile. Apple's own icons put
                      # roughly this much glyph inside a tile that fills the
                      # canvas; 86% left almost no margin at all
MARK_FRACTION=0.94    # the standalone mark keeps a little breathing room

# Centring is geometric, not optical.
#
# `trim` can put the centre of MASS at the canvas centre, which is right for a
# mark whose visual weight sits away from the middle of its bounding box — a
# triangle, an arrow. It is wrong for this one. The petals are close to
# symmetric, so the eye reads the bounding box, and mass-centring pushed the
# glyph 42px right of centre in the tile (margins L164 R122) and left the
# standalone mark with a 3px right margin against 58 on the left.
#
# Pass `optical` as trim's last argument to go back, and measure the margins
# afterwards rather than trusting either mode to look right.

[ -f "$MASTER" ] || { echo "missing $MASTER" >&2; exit 1; }
mkdir -p "$BIN"
echo "==> master"
# 2048 across, so every downstream size is a reduction and never an
# enlargement.
swift "$REPO/tools/svg-render.swift" "$MASTER" "$SRC" 2048 || {
  echo "could not render $MASTER" >&2; exit 1; }
if [ -n "$DEV" ]; then
  ICON_SRC="$BIN/mark-master-dev.png"
  swift "$REPO/tools/svg-render.swift" "$MASTER" "$ICON_SRC" 2048 invert || {
    echo "could not render the inverted $MASTER" >&2; exit 1; }
fi
command -v swiftc >/dev/null 2>&1 || { echo "swiftc missing: xcode-select --install" >&2; exit 1; }

mkdir -p "$BIN" "$ICON/Assets" "$REPO/docs/img"

if [ ! -x "$BIN/trim" ] || [ "$REPO/tools/trim.swift" -nt "$BIN/trim" ]; then
  swiftc -O "$REPO/tools/trim.swift" -o "$BIN/trim"
fi

echo "==> mark"
"$BIN/trim" "$SRC" "$REPO/assets/mark.png"       1024 "$MARK_FRACTION" "$ALPHA_CUTOFF" 2>&1 | sed 's/^/    /'
"$BIN/trim" "$ICON_SRC" "$ICON/Assets/mark.png"  1024 "$ICON_FRACTION" "$ALPHA_CUTOFF" >/dev/null 2>&1
# The bare glyph the app draws inside its own windows. A development build gets
# the inverted one there too, so the About panel and the sheet headers agree
# with the Dock rather than contradicting it.
if [ -n "$DEV" ]; then
  "$BIN/trim" "$ICON_SRC" "$BIN/mark-dev.png"    1024 "$MARK_FRACTION" "$ALPHA_CUTOFF" >/dev/null 2>&1
  sips -z 256 256 "$BIN/mark-dev.png" --out "$BIN/mark-256-dev.png" >/dev/null
fi

# --- the manifest -----------------------------------------------------------
# system-light / system-dark tell the system to draw its own tile per
# appearance. That is the whole point: one artwork, four appearances.
cat > "$ICON/icon.json" <<'JSON'
{
  "fill-specializations": [
    { "value": "system-light" },
    { "appearance": "dark", "value": "system-dark" }
  ],
  "groups": [
    {
      "blur-material": null,
      "hidden": false,
      "lighting": "individual",
      "shadow": { "kind": "layer-color", "opacity": 0.5 },
      "specular-specializations": [
        { "value": true },
        { "appearance": "tinted", "value": true }
      ],
      "translucency-specializations": [
        { "value": { "enabled": true, "value": 0.5 } },
        { "appearance": "dark", "value": { "enabled": false, "value": 0.5 } },
        { "appearance": "tinted", "value": { "enabled": true, "value": 0.5 } }
      ],
      "layers": [
        { "glass": false, "hidden": false, "image-name": "mark.png", "name": "Mark" }
      ]
    }
  ],
  "supported-platforms": { "squares": ["macOS"] }
}
JSON
echo "    AppIcon.icon written"

if [ -n "$DEST" ]; then
  [ -d "$DEST" ] || { echo "no app bundle at $DEST" >&2; exit 1; }
  mkdir -p "$DEST/Contents/Resources"
  xcrun actool "$ICON" --compile "$DEST/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$BUILD/icon.plist" >/dev/null
  # Only the compiled form. The source .icon used to be copied in beside it
  # "the way shipping apps do", which is not a thing shipping apps do: nothing
  # in /System/Applications carries a .icon in Resources. The system reads
  # Assets.car via CFBundleIconName, which actool has just written above.
  #
  # Still removed rather than merely not copied, so a bundle built before this
  # does not keep it forever.
  rm -rf "$DEST/Contents/Resources/AppIcon.icon"
  echo "    compiled into the bundle (Assets.car + AppIcon.icns)"
fi

sips -z 256 256 "$REPO/assets/mark.png" --out "$REPO/docs/img/mark-256.png" >/dev/null
echo "    docs/img/mark-256.png written"
