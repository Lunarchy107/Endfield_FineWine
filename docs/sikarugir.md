# Sikarugir engine (no CrossOver)

> ⚠️ **Experimental.** Verified once on an Apple M1 (2026-10-16): Steam connects and signs in, and Endfield (Steam build, `-force-d3d11`) passes ACE, logs in and renders. The proven setup is still CrossOver 26.3 ([installation.md](installation.md)).

[Sikarugir](https://github.com/Sikarugir-App/Sikarugir) (the Wineskin successor maintained by Gcenx) wraps each Windows app in its own `.app`, running a Wine **engine**: a self-contained `wswine.bundle` shipped as a `WS12Wine….tar.xz`. Instead of patching CrossOver, this path builds CrossOver 26.3 Wine with [Highball](https://github.com/gauthierpiarrette/highball-engine)'s patch series plus this repo's patches as a **complete** engine for Sikarugir.

## Why not swap modules into a Sikarugir engine?

The CrossOver route swaps three patched modules into an otherwise-stock CrossOver. That needs the rest of the Wine tree to come from the same source. Sikarugir's own engines don't:

| | CrossOver 26.3 | `WS12WineSikarugir11.0_1` | `WS12WineSikarugir10.0_8` | `WS12WineCX24.0.7_7` |
|---|---|---|---|---|
| Base | CrossOver (Wine 11.0) | upstream Wine 11.0 + Sikarugir/CrossOver patches | upstream Wine 10.0 + patches | CrossOver 24.0.7 (Wine 9.0) |
| wineserver protocol | 1809 | 931 (upstream 930) | 856 (upstream 855) | 1795 (matches public source) |
| `handle_cet_nop` (stage-1 NOP fix hooks here) | ✅ | ❌ | | ✅ |
| `emulate_xgetbv`, msync, GPTK hook | ✅ | ✅ | | ✅ |

A CrossOver-built `ntdll.so` refuses to talk to a protocol-931 wineserver, and the source of Sikarugir's 11.0 engine isn't published. A full engine built from CrossOver 26.3 sidesteps both: it's the same Wine as the proven CrossOver setup, and Sikarugir only supplies the launcher, the runtime libraries (`Contents/Frameworks`) and the renderers (DXMT, D3DMetal, DXVK).

## Requirements

| | |
|---|---|
| **Mac / macOS / Rosetta** | as in [installation.md](installation.md) |
| **Sikarugir** | `brew install --cask sikarugir` (Sikarugir Creator); a wrapper made with it supplies the runtime libraries and renderers |
| **MacPorts** | [macports.org](https://www.macports.org), configured to build x86_64 (below). Homebrew's x86_64 support is Tier 3, so the full build uses MacPorts, like Gcenx's own Wine builds. |
| **Disk / time** | ~10 GB for the build tree; a full build is ~30–60 min |

## 1. MacPorts setup (once)

```bash
# Build every port as x86_64 (per Gcenx/macports-wine; do this before installing any port)
echo "build_arch x86_64" | sudo tee -a /opt/local/etc/macports/macports.conf

# Gcenx's overlay of Wine-oriented ports; it must come before the default source
sudo git clone https://github.com/Gcenx/macports-wine.git /opt/macports-wine
sudo sed -i '' 's|^rsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz \[default\]|file:///opt/macports-wine\
&|' /opt/local/etc/macports/sources.conf
sudo port -v sync
cd /opt/macports-wine && sudo portindex

sudo port install bison flex gettext pkgconfig MoltenVK-latest \
                  x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc \
                  gnutls freetype libsdl2 vulkan-loader libpcap
```

## 2. Build and package

```bash
./scripts/build-wine.sh engine             # fetch -> apply -> engine-configure -> engine-build
./scripts/package-sikarugir-engine.sh      # -> dist/WS12WineFineWine26.3.0_1.tar.xz
INSTALL=1 ./scripts/package-sikarugir-engine.sh   # same, and copy it into Sikarugir's Engines folder
```

`engine` applies Highball's series (`patches/highball/`, 22 patches, with `patch -p1` as Highball's own build does) then this repo's 46, then the two Sikarugir-only fixes in `patches/sikarugir/` (70 in all), and builds the whole tree (i386 + x86_64 PE via mingw-w64 GCC, new WoW64; no `cx-llvm`). The configure options follow Gcenx's `wine-devel` Portfile, adjusted to Highball's build: GCC rather than `llvm-mingw` for the PE side, no `libinotify`, no CUPS. Steam does not connect on an otherwise identical engine built with `llvm-mingw` and `libinotify` (see Known issues). The packager rewrites MacPorts library links to `@rpath/…` (resolved from the wrapper's `Frameworks` at runtime, like Sikarugir's engines) and fails if any `/opt/local` reference remains, adds Wine Gecko and Mono (WineHQ's releases, downloaded once into `build/addons` and checked against pinned SHA-256 sums; `REF_ENGINE=<engine.tar.xz>` copies them from a Sikarugir engine instead), ad-hoc signs every Mach-O and writes the tarball.

## 3. Use it

Test on a **copy** of a wrapper (or a new one from Sikarugir Creator), not your only one:

1. Point the wrapper at the engine (Creator → new wrapper with engine `WS12WineFineWine26.3.0_1`, or the wrapper's Configure → change engine).
2. Renderer: **DXMT**. Keep MSync on. Always pass `-force-d3d11` to the game. Without it the game silently falls back to Vulkan (through MoltenVK): it still runs, but its Vulkan pipeline cache fails to load (`Vulkan PSO: Failed to read cache data` in `Player.log`), so every launch recompiles all its shaders. With D3D11 through DXMT the first launch builds the cache and later launches reuse it. `Player.log` (in `AppData/LocalLow/Gryphline/Endfield`) shows `Forcing GfxDevice: Direct3D 11` when the flag took effect.
   - **Steam version:** `Endfield.exe` can't be started on its own; it quits and relaunches through Steam. Set the wrapper's program to Steam's `steam.exe` and its Program Flags to `-silent -applaunch 4732690 -force-d3d11`: opening the wrapper then starts the game directly, Steam stays in the background without its window, and the arguments after the app ID go to the game. Clear the flags to get Steam's window back. Choosing **DirectX 11** in Steam's launch dialog also passes the flag, but plain **Play** doesn't.
   - **Gryphline launcher:** choose "Launch with DirectX 11" from the dropdown next to Start.
   - **Steam's UI** needs no extra flags. Steam's UI (Chromium) draws from its GPU process into a window owned by its browser process, a "cross-process swapchain". `patches/highball/0007` lets `winemac` host that, and the packaged engine's `dxmt_extescape` marker makes the launcher set `DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN`. Without both, Steam runs but its window never appears (`CreateSwapChain: cross-process swapchain not supported yet` in the log). Steam's `-cef-disable-gpu -cef-disable-gpu-compositing` is not a workaround here: the window shows but stays black.
3. In-game: don't use NVIDIA DLSS (black screen under DXMT); use TAAU or FSR3.

## 4. Updating the wrapper template

A wrapper's launcher, Configure, runtime libraries (`Contents/Frameworks`) and renderers come from Sikarugir's **template**. Sikarugir Creator downloads the newest template, but only uses it for new wrappers; an existing wrapper keeps its version until you update it. Updating doesn't touch the engine or the prefix (`Contents/SharedSupport/wine` and `prefix`), so this engine and your Steam login and games stay as they are. Verified from template 1.0.21 to 1.0.24.

1. Open **Sikarugir Creator** so it downloads the newest template. Configure updates from whatever template Creator has, not from the internet.
2. Close the wrapper, then in its **Configure** click **Update Wrapper**. This replaces `Contents/Configure.app`, `MacOS`, `Frameworks` and `Resources/vulkan`; the settings in `Info.plist` (Program Flags, MSync, renderer, …) are kept.
3. **From template 1.0.22 or older, update a second time.** Since 1.0.23 the renderers live in `Contents/SharedSupport/renderer/` instead of `Contents/Frameworks/renderer/`. The first update runs the old Configure, which installs the new `Frameworks` (without renderers) but never writes `SharedSupport`, so the wrapper is left with no DXMT, D3DMetal or DXVK. The second update runs the new Configure, which installs them. Without them, games fall back to Wine's built-in renderer and Steam's window can stay black.

To check: `Contents/SharedSupport/renderer/` should contain `dxmt`, `d3dmetal`, `dxvk` and `d9vk`. The engine also loads `libgnutls.30`, `libfreetype.6`, `libSDL2-2.0.0`, `libvulkan.1` and `libpcap.A` from the wrapper's `Frameworks` by name; a template that renamed one of them would need an engine rebuild. Template 1.0.24 still has all five. Duplicating the wrapper in Finder before updating costs almost no disk space on APFS and gives you a copy to fall back on.

## Known issues

- **After a major macOS upgrade, MacPorts' `port` refuses to run** (`Current platform "darwin 27" does not match expected platform "darwin 25"`) until it is migrated: install the MacPorts release for the new macOS, then `sudo port migrate`, which reinstalls every port and, without prebuilt x86_64 packages for a new macOS, may compile them all from source for hours. The installed tools and libraries keep working meanwhile, so `MACPORTS_SKIP_PORT_CHECK=1 ./scripts/build-wine.sh engine` builds anyway (it checks the needed files exist instead of asking `port`). Seen going from macOS 26.6.2 to 27.0.1 with MacPorts 2.12.
- **Gryphline launcher (Qt WebEngine) was blank white** until `patches/sikarugir/0002`: Sikarugir's launcher sets `QMLSCENE_DEVICE=softwarecontext` for every wrapper. Fixed in the engine; nothing to set per wrapper.
- **Turn D9VK off** in Gryphline launcher wrappers (`D9VK` = 0 in the wrapper's `Info.plist`; Configure has no checkbox for it). The launcher draws through Direct3D 9, and D9VK's Vulkan output doesn't reach the window on this engine. Wine's built-in Direct3D 9 works. Vulkan presentation in general (D9VK, DXVK, a game's Vulkan mode) is likely affected the same way.
- **Steam needs the GCC build.** With the same patches but PE modules from `llvm-mingw` and a `libinotify` wineserver, Steam loops on `EConnect called - scheduling connection for 50ms from now` and never reaches Valve's servers: 3 of 3 runs failed, against 3 of 3 passes for Highball's engine alternating in the same wrapper. Built like Highball (GCC, no `libinotify`, no CUPS), it passed 3 of 3 the same way. Which of the two changes matters was not isolated. Swapping single modules between engines gave inconsistent results, so the cause is not pinned to one file.
- **Highball's `0014-msync-unregister-early-return` is left out.** It fixes a wineserver leak from the client side: a multi-object wait that returns early leaves its registration behind, and on a rarely signaled object these pile up (Highball's scenario grew the wineserver from 18 to 54 MB in 30 s, with a pool warning on every allocation). This repo fixes the same leak on the server side instead, with `patches/stage1-macos/0006`: no growth, and wake latency as low as with `0014` (test program: `tests/fixtures/msync-wait-stress.c`). The reason for preferring it: with `0014` and MSync on, Endfield's gameplay once ignored the keyboard and mouse (2026-10-16, macOS 26.6.2), and Wine processes outlived the wineserver after quitting. After updating to macOS 27.0.1 (new Command Line Tools, reinstalled Rosetta), neither reproduced with `0014` alone or combined with this repo's msync patches `0004`/`0005`, so the cause is unknown and may have been intermittent. One run with `0014` + `0005` left Steam's renderer and the wineserver running after quitting; `wineserver -k` cleared them.
- **User profile.** `patches/highball/0001` names the Windows user after the macOS user instead of CrossOver's `crossover`; Steam needs this to find a saved login. Sikarugir links the profile names to one folder in its prefixes.
- **Game account (Steam build).** The game signs in through the Steam account that is logged in, and Gryphline's servers decide which game account that is; there is no logout in the game. Deleting `AppData/LocalLow/Gryphline/Endfield` only clears the local cache: the same account comes back. To use another game account, sign Steam into the Steam account linked to it.

## Known unknowns

- **Renderer selection** works through environment variables (`WINEDLLPATH_DXMT`, `WINEDLLPATH_D3DMETAL`, …, or `WINEDLLPATH_PREPEND`) that the launcher points at `Contents/SharedSupport/renderer/<name>` (template 1.0.23 and later; `Contents/Frameworks/renderer/<name>` before). Stock CrossOver Wine ignores them, so `patches/highball/0003` (`WINEDLLPATH_PREPEND`) and `patches/sikarugir/0001` (the others) add support. Without it every Direct3D app falls back to `wined3d` (Steam's window never opens). Confirmed: with it, Steam's web helper loads DXMT (`winemetal.dll`) and renders.
- **`dxmt_extescape` marker.** An empty file in the engine (present in Sikarugir's 11.0_1, absent in CX24). It doesn't select DXMT; with it the launcher sets `DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN`, which `patches/highball/0007` serves. The packager adds it by default (`DXMT_EXTESCAPE=0` leaves it out). Verified with Steam's web helper: Apple M1 through DXMT, no GPU-process restarts.
- **Highball's Rosetta patches** `0009`, `0011`, `0013` and `0016` change how the TEB's `%gs` slots and DEP behave under Rosetta, the same area as this repo's VMProtect/ACE fixes. ACE passed with them in the test above; if it regresses, test without them first.
- **GStreamer** is not built in (`--without-gstreamer`), so Wine-side media playback is unavailable. Unity's own video player doesn't use it.
- Sikarugir's own patches (e.g. `SIKARUGIR_*` environment switches) are not in this engine.
- Sharing the engine means distributing LGPL Wine: `SOURCE.txt` inside the bundle records the source and patch commit.
