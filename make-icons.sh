#!/usr/bin/env bash
#
# Build every graphic from one source: assets/mark-source.png.
#
# The source is the logo as supplied — transparent, but with uneven padding and
# a thin matte fringe of strongly-coloured near-transparent pixels around the
# edges. Both are dealt with here rather than by hand, so the whole set is
# reproducible from that one file:
#
#   1. drop fringe pixels below an alpha cutoff. This is not only tidiness —
#      the speckles sit outside the real artwork, so they drag the bounding box
#      outward and take the centring with it.
#   2. trim to the true content bounds and centre OPTICALLY: on the artwork's
#      centre of mass rather than the middle of its box. The cards lean left,
#      so the two differ by about 1%.
#   3. composite onto light and dark tiles, rendered through WebKit so CSS
#      gradients, shadows and blend modes behave as they do in a browser.
#   4. compile an asset catalogue with real appearance variants via actool.
#
# Needs only the Xcode command line tools, which are already required to build
# the app: swiftc, sips, actool.
#
#   ./make-icons.sh                 docs images only
#   ./make-icons.sh <App.app>       and compile icons into that bundle

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-}"
BUILD="$REPO/build"
BIN="$BUILD/bin"
SET="$BUILD/Icons.xcassets/AppIcon.appiconset"
SRC="$REPO/assets/mark-source.png"

ALPHA_CUTOFF=0.22     # below this, a pixel is fringe rather than soft edge
TILE_FRACTION=0.68    # how much of the app tile the mark occupies
MARK_FRACTION=0.94    # the standalone mark keeps a little breathing room, which
                      # also leaves the optical nudge somewhere to move to

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "swiftc missing: xcode-select --install" >&2; exit 1; }

mkdir -p "$SET" "$BIN" "$REPO/docs/img"

# --- tools, rebuilt only when their source changes -------------------------
for t in trim render; do
  if [ ! -x "$BIN/$t" ] || [ "$REPO/tools/$t.swift" -nt "$BIN/$t" ]; then
    swiftc -O "$REPO/tools/$t.swift" -o "$BIN/$t"
  fi
done

echo "==> mark"
# The canonical mark: cleaned, trimmed, optically centred, transparent.
"$BIN/trim" "$SRC" "$REPO/assets/mark.png" 1024 "$MARK_FRACTION" "$ALPHA_CUTOFF" optical 2>&1 | sed 's/^/    /'
# The same, inset for use inside a tile.
"$BIN/trim" "$SRC" "$BUILD/tile-mark.png" 1024 "$TILE_FRACTION" "$ALPHA_CUTOFF" optical >/dev/null 2>&1

# --- tiles ------------------------------------------------------------------
tile() {  # name, background, inner-rim, shadow
  cat > "$BUILD/tile-$1.html" <<HTML
<style>
  html,body{margin:0;padding:0;width:1024px;height:1024px;overflow:hidden}
  .tile{position:absolute;inset:0;border-radius:230px;overflow:hidden;background:$2}
  .sheen{position:absolute;inset:0;border-radius:230px;
         background:linear-gradient(148deg,rgba(255,255,255,.18) 0%,rgba(255,255,255,0) 46%)}
  .rim{position:absolute;inset:0;border-radius:230px;
       box-shadow:inset 0 3px 0 $3, inset 0 -3px 0 rgba(255,255,255,.05)}
  img{position:absolute;left:0;top:0;width:1024px;height:1024px;filter:drop-shadow(0 20px 32px $4)}
</style>
<div class="tile"><img src="tile-mark.png"><div class="sheen"></div><div class="rim"></div></div>
HTML
  "$BIN/render" "$BUILD/tile-$1.html" "$BUILD/icon-$1.png" 1024
}
tile light 'linear-gradient(150deg,#FFFFFF 0%,#EFF0F4 52%,#DEE0E8 100%)' 'rgba(0,0,0,.07)' 'rgba(0,0,0,.13)'
tile dark  'linear-gradient(150deg,#3A3F49 0%,#22262E 50%,#101318 100%)' 'rgba(255,255,255,.26)' 'rgba(0,0,0,.48)'
echo "    tiles rendered"

# --- asset catalogue --------------------------------------------------------
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  size="${spec%%:*}"; scale="${spec#*:}"; px=$((size * scale))
  sips -z "$px" "$px" "$BUILD/icon-light.png" --out "$SET/light-${size}x${size}@${scale}x.png" >/dev/null
  sips -z "$px" "$px" "$BUILD/icon-dark.png"  --out "$SET/dark-${size}x${size}@${scale}x.png"  >/dev/null
done
python3 - "$SET" <<'PY'
import json, sys
d = sys.argv[1]; images = []
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        base = {"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x"}
        images.append({**base, "filename": f"light-{size}x{size}@{scale}x.png"})
        images.append({**base, "filename": f"dark-{size}x{size}@{scale}x.png",
                       "appearances": [{"appearance": "luminosity", "value": "dark"}]})
json.dump({"images": images, "info": {"author": "runbranch", "version": 1}},
          open(f"{d}/Contents.json", "w"), indent=2)
PY

if [ -n "$DEST" ]; then
  [ -d "$DEST" ] || { echo "no app bundle at $DEST" >&2; exit 1; }
  mkdir -p "$DEST/Contents/Resources"
  xcrun actool "$BUILD/Icons.xcassets" --compile "$DEST/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$BUILD/icon.plist" >/dev/null
  echo "    Assets.car + AppIcon.icns compiled into the bundle"
fi

# --- images the README actually uses --------------------------------------
# Only these are committed. assets/mark.png is the full-size clean mark, and
# everything else is a resize of it, so committing several sizes was storing
# the same picture four times.
sips -z 256 256 "$REPO/assets/mark.png" --out "$REPO/docs/img/mark-256.png" >/dev/null
sips -z 512 512 "$BUILD/icon-light.png" --out "$BUILD/icon-light-512.png" >/dev/null
sips -z 512 512 "$BUILD/icon-dark.png"  --out "$BUILD/icon-dark-512.png"  >/dev/null
echo "    docs/img/mark-256.png written; tile previews in build/"
