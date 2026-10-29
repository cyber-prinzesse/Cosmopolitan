# Third-party notices

Cosmopolitan's own code is covered by its LICENSE only. Everything below is separate
software with its own terms. Versions are what this Mac currently runs; the app's
weekly update job records the installed version next to each component.

## D3DMetal (Apple Game Porting Toolkit) — Apple proprietary, NOT bundled

D3DMetal (`D3DMetal.framework`, `libd3dshared.dylib`, the `d3d11/d3d12/dxgi` bridge DLLs,
`nvngx`/`nvapi64` bridges) is Apple Inc.'s closed-source software, licensed under the
*Software License Agreement for Game Porting Toolkit*. It is never shipped with this app,
never committed to its repository, never modified and never redistributed.

The user obtains the Game Porting Toolkit from Apple directly
(https://developer.apple.com/games/game-porting-toolkit/), selects the downloaded files in
Cosmopolitan, reads Apple's license as shipped in that download, and accepts it explicitly.
Acceptance (date + SHA-256 of the license file) is stored in
`~/Library/Application Support/Cosmopolitan/d3dmetal-license.json`; a changed license asks
again. Without acceptance the D3DMetal backend is disabled and games fall back to DXMT, DXVK
or Wine's own Direct3D. "Remove D3DMetal" deletes the files and withdraws the acceptance.
D3DMetal is never behind any paid feature.

## Wine (Sikarugir build "WS12WineSikarugir") — LGPL-2.1

Wine and the Sikarugir Wine-based components are LGPL-2.1. Sources for the exact versions:
https://github.com/Sikarugir-App/Sikarugir-foss-sources. The Sikarugir Launcher itself is
not LGPL and none of its code is used here.

## DXMT — see upstream COPYING.LIB per version

https://github.com/3Shain/dxmt. The license of recent versions must be read from the
repository's COPYING.LIB before redistribution; the version installed here is recorded in
`engines/renderer/dxmt/version`.

## DXVK / D9VK (Sikarugir builds of DXVK-macOS) — zlib

https://github.com/Gcenx/DXVK-macOS, https://github.com/doitsujin/dxvk.

## MoltenVK — Apache-2.0

https://github.com/KhronosGroup/MoltenVK.

## GStreamer framework — LGPL-2.1 (plugins carry their own licenses)

https://gstreamer.freedesktop.org/. Shipped as the framework from the Sikarugir template;
plugin licenses are inside the framework's Resources.

## cnc-ddraw — MIT

https://github.com/FunkyFr3sh/cnc-ddraw.

## SDL2 / SDL3 — zlib

https://libsdl.org/.

## winetricks — LGPL-2.1 (installed via Homebrew, not bundled)

https://github.com/Winetricks/winetricks.

## DOSBox Staging — GPL-2.0 (installed via Homebrew, not bundled)

https://www.dosbox-staging.org/.

## Sparkle 2.10.0 — MIT (bundled, `Contents/Frameworks/Sparkle.framework`)

https://sparkle-project.org — software update framework; updates are EdDSA-signed.

## Data sources used at run time (not bundled)

- Highball database — curated game data CC0-1.0; `db/derived` predictions ODbL-1.0;
  anti-cheat map MIT (from AreWeAntiCheatYet). https://github.com/gauthierpiarrette/highball-db
- ProtonDB summaries — https://www.protondb.com (community reports, used as an expectation only).
- umu-protonfixes — https://github.com/Open-Wine-Components/umu-protonfixes (per-game fix
  scripts; only declarative settings are read from them, no code is executed).

## Ideas adapted from other projects (not bundled)

- abduzeedo/mapc-engine (Apache-2.0) — https://github.com/abduzeedo/mapc-engine. Runtime Direct3D 12
  detection cues (Agility SDK / DXIL beside the exe, `D3D12CreateDevice` string) and setting
  `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` so CrossOver's win32u reports GPU scheduling to DX12 games.
  No mapc-engine code is shipped; Cosmopolitan reimplements the ideas in its own launch check / env.
