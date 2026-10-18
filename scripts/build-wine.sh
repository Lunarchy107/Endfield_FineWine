#!/usr/bin/env bash
# build-wine.sh — build a 64-bit-only CrossOver Wine from source on Apple Silicon, so we can
# apply patches and experiment (stage 1) and eventually the dw-proton set (stage 2).
#
# WHY 64-bit only: Arknights: Endfield is a pure 64-bit game (Endfield.exe @ 0x140000000, all game
# DLLs 64-bit). We do NOT need win32on64 / the (now-unavailable) cx-llvm patched clang. A 64-bit
# Wine builds with the STANDARD toolchain. See docs/04-building-crossover-wine.md.
#
# This produces an x86_64 Wine (runs under Rosetta 2 — the config where dw-proton's #ifdef __x86_64__
# int3 hack compiles, and the same config where our stage-1 fault occurs).
#
# STATUS: verified with the CrossOver 26.3.0 sources — builds clean 64-bit-only on the CI builder
# (GitHub's xcode-27 image) and locally on an M4 / macOS 27.0 with Command Line Tools 16 (~10 min
# on its 10 cores).
#
# Usage:
#   scripts/build-wine.sh deps      # install Homebrew build deps
#   scripts/build-wine.sh fetch     # download + extract CrossOver 26.3 wine source, init git
#   scripts/build-wine.sh apply     # git apply all patches/ (em-backports -> misc -> ace-core -> macos fixes)
#   scripts/build-wine.sh configure # run ./configure (64-bit)
#   scripts/build-wine.sh build     # make -j
#   scripts/build-wine.sh all       # deps -> fetch -> apply -> configure -> build
#
# Full engine (a complete i386+x86_64 Wine for Sikarugir, packaged by package-sikarugir-engine.sh).
# Needs an x86_64 MacPorts in /opt/local (build_arch x86_64) plus the Gcenx/macports-wine overlay;
# see docs/sikarugir.md for the port list.
#   scripts/build-wine.sh engine-configure  # ./configure the full tree against MacPorts + mingw-w64 GCC
#   scripts/build-wine.sh engine-build      # make -j, then install into build/wine-engine-root
#   scripts/build-wine.sh engine-apply      # patches/highball/, then the patches 'apply' uses, then patches/sikarugir/
#   scripts/build-wine.sh engine            # fetch -> engine-apply -> engine-configure -> engine-build
#
# Env: CX_VER (default 26.3.0), BUILD_DIR (default ./build), JOBS (default: all cores),
#      MACPORTS (default /opt/local)

set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CX_VER="${CX_VER:-26.3.0}"
BUILD_DIR="${BUILD_DIR:-$REPO/build}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SRC_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VER}.tar.gz"
WINE_SRC="$BUILD_DIR/wine-src"          # extracted sources/wine
WINE_BUILD="$BUILD_DIR/wine-build64"    # out-of-tree 64-bit build
WINE_OUT="$BUILD_DIR/wine-out"
MODULES="dlls/ntdll/ntdll.so dlls/kernel32/x86_64-windows/kernel32.dll dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe programs/lsass/x86_64-windows/lsass.exe programs/wineboot/x86_64-windows/wineboot.exe server/wineserver"
ENGINE_BUILD="$BUILD_DIR/wine-build-engine"  # out-of-tree full i386+x86_64 build
ENGINE_ROOT="$BUILD_DIR/wine-engine-root"    # installed tree: bin/ lib/wine/ share/wine/
MACPORTS="${MACPORTS:-/opt/local}"
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
# Engine mode matches Gcenx's wine Portfiles (14.0 on macOS 15+ hosts, wine MR 5935).
case "${1:-}" in engine*) export MACOSX_DEPLOYMENT_TARGET=14.0 ;; *) export MACOSX_DEPLOYMENT_TARGET=10.15 ;; esac

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
use_bison(){ export PATH="$("$BREW" --prefix bison)/bin:$PATH"; }  # Wine needs bison >= 3.0; macOS ships 2.3

cmd_deps() {
  log "Installing Homebrew build dependencies"
  # ccache wraps CC/CXX on CI (the workflow sets "CC: ccache clang"); include it here so a
  # cache-miss build installs it too.
  "$BREW" install bison mingw-w64 pkgconf ccache || exit 1
}

cmd_fetch() {
  log "Fetching CrossOver ${CX_VER} source (~150 MB) and extracting sources/wine"
  mkdir -p "$BUILD_DIR"
  local tgz="$BUILD_DIR/crossover-sources-${CX_VER}.tar.gz"
  [ -f "$tgz" ] || curl -fL "$SRC_URL" -o "$tgz" || { echo "download failed ($SRC_URL)"; exit 1; }
  rm -rf "$WINE_SRC" "$BUILD_DIR/sources"; mkdir -p "$WINE_SRC"
  tar xzf "$tgz" -C "$BUILD_DIR" sources/wine || { echo "extract failed"; exit 1; }
  mv "$BUILD_DIR/sources/wine"/* "$WINE_SRC/"; rm -rf "$BUILD_DIR/sources"
  # Commit a baseline for inspecting patch changes.
  ( cd "$WINE_SRC" && git init -q && git add -A && git -c user.email=build@localhost -c user.name=build commit -qm "vanilla CrossOver ${CX_VER} wine" ) || exit 1
  echo "Wine source: $WINE_SRC ($(cat "$WINE_SRC/VERSION"))"
}

cmd_apply() {
  local mode="${1:-}"
  log "Applying patches (${mode:+highball -> }em-backports -> misc -> ace-core -> macOS${mode:+ -> sikarugir})"
  [ -d "$WINE_SRC/.git" ] || { echo "run 'fetch' first"; exit 1; }
  local P="$REPO/patches"
  ( cd "$WINE_SRC"
    n=0
    # The Sikarugir engine starts from Highball's CrossOver 26.3 series, applied the way its own
    # build applies it (patch -p1; several hunks need fuzz against this source).
    if [ "$mode" = engine ]; then
      for f in $(ls "$P"/highball/*.patch | sort); do
        patch -p1 -s --no-backup-if-mismatch < "$f" || { echo "patch failed: $f"; exit 1; }
        n=$((n+1))
      done
    fi
    for f in $(ls "$P"/stage2-dwproton/em-backports/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/misc/*.patch | sort) \
             $(ls "$P"/stage2-dwproton/ace-core/*.patch | sort) \
             $(ls "$P"/stage1-macos/*.patch | sort); do
      git apply "$f" || { echo "patch failed: $f"; exit 1; }
      n=$((n+1))
    done
    # Fixes only the Sikarugir engine needs (its launcher's environment); the CrossOver build
    # leaves them out.
    if [ "$mode" = engine ]; then
      for f in $(ls "$P"/sikarugir/*.patch | sort); do
        git apply "$f" || { echo "patch failed: $f"; exit 1; }
        n=$((n+1))
      done
    fi
    echo "applied $n patches" ) || exit 1
}

cmd_configure() {
  log "Configuring 64-bit-only Wine"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  rm -rf "$WINE_BUILD"; mkdir -p "$WINE_BUILD"
  use_bison
  # Matching build/host lets configure run x86_64 probes under Rosetta while shell tools
  # stay native. Disable optional libraries: Homebrew's are arm64, and these modules don't need them.
  ( cd "$WINE_BUILD" && CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" "$WINE_SRC/configure" \
      --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-archs=x86_64 \
      --disable-tests --without-x --without-freetype --without-gnutls --without-sdl --without-vulkan \
      --without-krb5 --without-gstreamer --without-gphoto --without-sane --without-pcap --without-usb \
      --without-cups --without-coreaudio
  ) 2>&1 | tee "$BUILD_DIR/configure.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "configure failed — see $BUILD_DIR/configure.log"; exit 1; }
  # Supply library names used by win32u even with --without-vulkan.
  local cfg="$WINE_BUILD/include/config.h"
  sed -i '' 's|/\* #undef SONAME_LIBVULKAN \*/|#define SONAME_LIBVULKAN "libvulkan.1.dylib"|' "$cfg"
  sed -i '' 's|/\* #undef SONAME_LIBMOLTENVK \*/|#define SONAME_LIBMOLTENVK "libMoltenVK.dylib"|' "$cfg"
}

cmd_build() {
  local targets="$MODULES" m
  [ "${FULL:-0}" = "1" ] && targets=""
  log "Building ${targets:-the full tree} (make -j$JOBS)"
  [ -f "$WINE_BUILD/Makefile" ] || { echo "run 'configure' first"; exit 1; }
  use_bison
  # shellcheck disable=SC2086 # targets is a word list
  ( cd "$WINE_BUILD" && make -j"$JOBS" $targets ) 2>&1 | tee "$BUILD_DIR/build.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "make failed — see $BUILD_DIR/build.log"; exit 1; }
  rm -rf "$WINE_OUT"; mkdir -p "$WINE_OUT"
  for m in $MODULES; do cp "$WINE_BUILD/$m" "$WINE_OUT/" || exit 1; done
  cp "$WINE_SRC/COPYING.LIB" "$WINE_OUT/" || exit 1
  echo "$CX_VER" > "$WINE_OUT/CROSSOVER_VERSION"
  echo "$SRC_URL" > "$WINE_OUT/SOURCE_URL"
  echo "built $WINE_OUT"
}

# --- full engine (Sikarugir) ---------------------------------------------------------------------
# Unlike the minimal build above, this builds the whole tree (i386 + x86_64 PE via mingw-w64 GCC, new
# WoW64 — still no cx-llvm) with the optional libraries enabled, against an x86_64 MacPorts. Wine
# dlopens those libraries by install name at runtime; a Sikarugir wrapper supplies them from its
# Contents/Frameworks, so nothing from /opt/local ends up in the engine.

# winebuild looks up the mingw binutils (x86_64-w64-mingw32-dlltool, ...) on PATH; the mingw-w64
# GCC ports install them in $MACPORTS/bin.
use_macports(){
  export PATH="$MACPORTS/bin:$MACPORTS/sbin:$PATH" PKG_CONFIG_PATH="$MACPORTS/lib/pkgconfig"
}

check_macports() {
  local p missing=""
  [ -x "$MACPORTS/bin/port" ] || { echo "MacPorts not found at $MACPORTS"; exit 1; }
  grep -qE '^build_arch[[:space:]]+x86_64' "$MACPORTS/etc/macports/macports.conf" \
    || { echo "MacPorts must be configured with 'build_arch x86_64' (see docs/sikarugir.md)"; exit 1; }
  # After a major macOS upgrade `port` refuses to run until `sudo port migrate`, although the
  # installed tools and libraries still work. MACPORTS_SKIP_PORT_CHECK=1 checks their files instead.
  if [ "${MACPORTS_SKIP_PORT_CHECK:-0}" = 1 ]; then
    for p in bin/bison bin/flex bin/msgfmt bin/pkg-config bin/x86_64-w64-mingw32-gcc bin/i686-w64-mingw32-gcc \
             lib/libgnutls.30.dylib lib/libfreetype.6.dylib lib/libSDL2-2.0.0.dylib lib/libvulkan.1.dylib lib/libpcap.A.dylib; do
      [ -e "$MACPORTS/$p" ] || missing="$missing $p"
    done
    [ -z "$missing" ] || { echo "missing MacPorts files:$missing"; exit 1; }
    echo "warning: not asking 'port' (MACPORTS_SKIP_PORT_CHECK=1); the needed files are present"
    return
  fi
  for p in bison flex gettext pkgconfig x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc gnutls freetype libsdl2 vulkan-loader libpcap; do
    "$MACPORTS/bin/port" -q installed "$p" 2>/dev/null | grep -q active || missing="$missing $p"
  done
  [ -z "$missing" ] || { echo "missing MacPorts ports:$missing (after a macOS upgrade: 'sudo port migrate', or MACPORTS_SKIP_PORT_CHECK=1)"; exit 1; }
}

cmd_engine_configure() {
  log "Configuring the full i386+x86_64 Wine against MacPorts ($MACPORTS)"
  [ -d "$WINE_SRC" ] || { echo "run 'fetch' first"; exit 1; }
  check_macports; use_macports
  rm -rf "$ENGINE_BUILD"; mkdir -p "$ENGINE_BUILD"
  # Options follow Gcenx's wine-devel Portfile (the recipe behind Sikarugir's engines), adjusted to
  # Highball's build, whose engine Steam connects on: PE modules from mingw-w64 GCC rather than
  # llvm-mingw, no libinotify (the server then watches directories with kqueue) and no CUPS.
  # Installed under the prefix /wswine.bundle so DESTDIR=$ENGINE_ROOT yields the engine layout directly.
  ( cd "$ENGINE_BUILD" && CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" \
      CPPFLAGS="-I$MACPORTS/include" LDFLAGS="-L$MACPORTS/lib" CROSSCFLAGS="-O2" "$WINE_SRC/configure" \
      --prefix=/wswine.bundle \
      --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-archs=i386,x86_64 \
      --with-mingw x86_64_CC=x86_64-w64-mingw32-gcc i386_CC=i686-w64-mingw32-gcc \
      --disable-tests --disable-winebth_sys \
      --with-coreaudio --with-freetype --with-gettext --with-gnutls \
      --with-opencl --with-pcap --with-pcsclite --with-pthread --with-sdl --with-vulkan \
      --without-alsa --without-capi --without-cups --without-dbus --without-ffmpeg --without-fontconfig \
      --without-gettextpo --without-gphoto --without-gssapi --without-gstreamer --without-inotify --without-krb5 \
      --without-netapi --without-opengl --without-oss --without-pulse --without-sane --without-udev \
      --without-usb --without-v4l2 --without-wayland --without-x
  ) 2>&1 | tee "$BUILD_DIR/engine-configure.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "configure failed — see $BUILD_DIR/engine-configure.log"; exit 1; }
}

cmd_engine_build() {
  log "Building the full engine tree (make -j$JOBS)"
  [ -f "$ENGINE_BUILD/Makefile" ] || { echo "run 'engine-configure' first"; exit 1; }
  use_macports
  ( cd "$ENGINE_BUILD" && make -j"$JOBS" ) 2>&1 | tee "$BUILD_DIR/engine-build.log"
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "make failed — see $BUILD_DIR/engine-build.log"; exit 1; }
  log "Installing into $ENGINE_ROOT"
  rm -rf "$ENGINE_ROOT"
  ( cd "$ENGINE_BUILD" && make install-lib DESTDIR="$ENGINE_ROOT" ) > "$BUILD_DIR/engine-install.log" 2>&1 \
    || { echo "install failed — see $BUILD_DIR/engine-install.log"; exit 1; }
  cp "$WINE_SRC/COPYING.LIB" "$ENGINE_ROOT/wswine.bundle/" || exit 1
  echo "$CX_VER" > "$ENGINE_ROOT/CROSSOVER_VERSION"
  echo "$SRC_URL" > "$ENGINE_ROOT/SOURCE_URL"
  echo "installed $ENGINE_ROOT/wswine.bundle"
}

case "${1:-all}" in
  deps|fetch|apply|configure|build) "cmd_$1" ;;
  all) cmd_deps; cmd_fetch; cmd_apply; cmd_configure; cmd_build ;;
  engine-configure) cmd_engine_configure ;;
  engine-build) cmd_engine_build ;;
  engine-apply) cmd_apply engine ;;
  engine) cmd_fetch; cmd_apply engine; cmd_engine_configure; cmd_engine_build ;;
  *) echo "usage: $0 [all|deps|fetch|apply|configure|build|engine|engine-apply|engine-configure|engine-build]"; exit 1 ;;
esac