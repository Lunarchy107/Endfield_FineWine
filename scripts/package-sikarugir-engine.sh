#!/usr/bin/env bash
# Package the full engine build (scripts/build-wine.sh engine) as a Sikarugir engine:
# dist/<ENGINE_NAME>.tar.xz containing wswine.bundle/{bin,lib/wine,share/wine,version}.
#
# Engines link their non-system libraries as @rpath/<name> and get them from the wrapper's
# Contents/Frameworks at runtime, so every /opt/local (MacPorts) reference is rewritten that way;
# packaging fails if any survives. Gecko and Mono are not built here: they are WineHQ's
# releases for this Wine version, downloaded once into $BUILD_DIR/addons and checked against
# the pinned SHA-256 sums below (or copied from a reference engine with REF_ENGINE).
#
# Usage:  scripts/package-sikarugir-engine.sh
# Env: BUILD_DIR (default <repo>/build), DIST_DIR (default <repo>/dist),
#      ENGINE_NAME (default WS12WineFineWine<CX_VER>_1),
#      REF_ENGINE=<engine .tar.xz> to copy Gecko and Mono from that Sikarugir engine instead of
#      downloading them (e.g. WS12WineSikarugir11.0_1 from Sikarugir's Engines folder),
#      DXMT_EXTESCAPE=0 to leave out the dxmt_extescape marker (with it, the launcher sets
#      DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN, which patches/highball/0007 serves),
#      INSTALL=1 to also copy the tarball into Sikarugir's Engines folder (FORCE=1 to overwrite).

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
DIST_DIR="${DIST_DIR:-$REPO/dist}"
ENGINE_ROOT="$BUILD_DIR/wine-engine-root"
ENGINES_DIR="$HOME/Library/Application Support/Sikarugir/Engines"
REF_ENGINE="${REF_ENGINE:-}"
ADDONS_DIR="$BUILD_DIR/addons"
# WineHQ's Gecko and Mono releases that CrossOver 26.3's Wine asks for (dlls/appwiz.cpl/addons.c).
# Identical to the copies in Sikarugir's WS12WineSikarugir11.0_1 engine (Mono adds an empty
# lib/mono/4.0 directory). Bump these together with the versions when the Wine base changes.
ADDONS_SHA256="wine-gecko-2.47.4-x86.tar.xz 2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6
wine-gecko-2.47.4-x86_64.tar.xz fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814
wine-mono-10.4.1-x86.tar.xz a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb"

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }
macho_files(){ find "$1/bin" "$1/lib/wine/x86_64-unix" -type f -exec sh -c 'file -b "$1" | grep -q "^Mach-O"' _ {} \; -print; }

[ -d "$ENGINE_ROOT/wswine.bundle/lib/wine" ] || die "no $ENGINE_ROOT; run scripts/build-wine.sh engine"
CX_VER="$(cat "$ENGINE_ROOT/CROSSOVER_VERSION")"
ENGINE_NAME="${ENGINE_NAME:-WS12WineFineWine${CX_VER}_1}"
[ -z "$REF_ENGINE" ] || [ -f "$REF_ENGINE" ] || die "reference engine not found: $REF_ENGINE"

stage="$DIST_DIR/$ENGINE_NAME"
bundle="$stage/wswine.bundle"
log "Staging $bundle"
rm -rf "$stage"; mkdir -p "$stage"
ditto "$ENGINE_ROOT/wswine.bundle" "$bundle"

gecko="$(sed -n 's/^#define GECKO_VERSION "\(.*\)"/\1/p' "$BUILD_DIR/wine-src/dlls/appwiz.cpl/addons.c")"
mono="$(sed -n 's/^#define MONO_VERSION "\(.*\)"/\1/p' "$BUILD_DIR/wine-src/dlls/appwiz.cpl/addons.c")"
[ -n "$gecko" ] && [ -n "$mono" ] || die "can't read the Gecko/Mono versions from wine-src"
if [ -n "$REF_ENGINE" ]; then
  log "Copying Gecko and Mono from $(basename "$REF_ENGINE")"
  tar -xJf "$REF_ENGINE" -C "$stage" wswine.bundle/share/wine/gecko wswine.bundle/share/wine/mono \
    || die "reference engine has no share/wine/{gecko,mono}"
  addons_src="copied unmodified from $(basename "$REF_ENGINE")"
else
  log "Fetching Gecko $gecko and Mono $mono from WineHQ (cached in $ADDONS_DIR)"
  mkdir -p "$ADDONS_DIR" "$bundle/share/wine/gecko" "$bundle/share/wine/mono"
  for f in "wine-gecko-$gecko-x86.tar.xz" "wine-gecko-$gecko-x86_64.tar.xz" "wine-mono-$mono-x86.tar.xz"; do
    sum="$(printf '%s\n' "$ADDONS_SHA256" | awk -v f="$f" '$1 == f {print $2}')"
    [ -n "$sum" ] || die "no pinned SHA-256 for $f; add it to ADDONS_SHA256"
    case "$f" in wine-gecko-*) url="https://dl.winehq.org/wine/wine-gecko/$gecko/$f" dir=gecko ;;
                 *)            url="https://dl.winehq.org/wine/wine-mono/$mono/$f"  dir=mono ;; esac
    if [ ! -f "$ADDONS_DIR/$f" ]; then
      curl -fsSL -o "$ADDONS_DIR/$f.part" "$url" || die "download failed: $url"
      mv "$ADDONS_DIR/$f.part" "$ADDONS_DIR/$f"
    fi
    echo "$sum  $ADDONS_DIR/$f" | shasum -a 256 -c --quiet - || die "SHA-256 mismatch: $ADDONS_DIR/$f"
    tar -xJf "$ADDONS_DIR/$f" -C "$bundle/share/wine/$dir" || die "extract failed: $f"
  done
  addons_src="WineHQ releases (dl.winehq.org), unmodified"
fi
[ -d "$bundle/share/wine/gecko/wine-gecko-$gecko-x86_64" ] || die "Gecko $gecko missing from share/wine/gecko"
[ -d "$bundle/share/wine/mono/wine-mono-$mono" ] || die "Mono $mono missing from share/wine/mono"

log "Rewriting MacPorts library references to @rpath"
while IFS= read -r f; do
  for dep in $(otool -L "$f" | awk 'NR>1 && $1 ~ /^\/opt\/local\// {print $1}'); do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
  done
  for rp in $(otool -l "$f" | awk '/cmd LC_RPATH/{r=1} r && /path /{print $2; r=0}' | grep '^/opt/local' || true); do
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null
  done
  if otool -L "$f" | grep -q /opt/local || otool -l "$f" | grep -q 'path /opt/local'; then
    die "$f still references /opt/local"
  fi
done < <(macho_files "$bundle")

commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$REPO" diff --quiet HEAD -- patches scripts 2>/dev/null || commit="$commit+dirty"
echo "WineCX $CX_VER FineWine ($commit)" > "$bundle/version"
[ "${DXMT_EXTESCAPE:-1}" = 1 ] && : > "$bundle/dxmt_extescape"
cat > "$bundle/SOURCE.txt" <<EOF
Wine (LGPL-2.1-or-later, see COPYING.LIB) built from:
  CrossOver $CX_VER source: $(cat "$ENGINE_ROOT/SOURCE_URL")
  patches and build scripts: $(git -C "$REPO" config --get remote.origin.url || echo unknown) @ $commit
Gecko $gecko and Mono $mono: $addons_src.
EOF

log "Signing (ad hoc) and clearing extended attributes"
xattr -cr "$bundle"
while IFS= read -r f; do codesign --force --sign - "$f" 2>/dev/null || die "codesign failed: $f"; done < <(macho_files "$bundle")

log "Creating $DIST_DIR/$ENGINE_NAME.tar.xz"
rm -f "$DIST_DIR/$ENGINE_NAME.tar.xz"
COPYFILE_DISABLE=1 tar -cJf "$DIST_DIR/$ENGINE_NAME.tar.xz" -C "$stage" wswine.bundle
( cd "$DIST_DIR" && shasum -a 256 "$ENGINE_NAME.tar.xz" > "$ENGINE_NAME.tar.xz.sha256" && cat "$ENGINE_NAME.tar.xz.sha256" )

if [ "${INSTALL:-0}" = 1 ]; then
  dest="$ENGINES_DIR/$ENGINE_NAME.tar.xz"
  [ ! -e "$dest" ] || [ "${FORCE:-0}" = 1 ] || die "$dest exists (FORCE=1 to overwrite)"
  cp "$DIST_DIR/$ENGINE_NAME.tar.xz" "$dest"
  echo "installed: $dest"
fi
echo "packaged: $DIST_DIR/$ENGINE_NAME.tar.xz"
