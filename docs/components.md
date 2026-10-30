# Components Cosmopolitan installs or loads, with source and pin

Updated 2026-10-23. Pins live in `Sources/Core/Components.swift`; nothing is installed unless its hash matches.
"Tree" = SHA-256 over every file's relative path and SHA-256 in a folder (`treeHash`). Each one is verified at setup before anything is copied.

## Installed now

| Component | Version | Source | Pin | Licence | Status |
|---|---|---|---|---|---|
| Wine engine | WS12WineSikarugir10.0_8 | github.com/Sikarugir-App/Engines, release v1.0 | tarball SHA-256 `2a6bcf2a3bf13cddf825599b6bc1e3659cbf71e1282c6d77141a92f6ac8d4c68` | LGPL-2.1-or-later | Sikarugir build; kept until an upstream engine passes the suite |
| Engine libraries (101 dylibs: MoltenVK `libMVK`, Vulkan loader, SDL2 + SDL3, freetype, gnutls, …) | from Template-1.0.24 | github.com/Sikarugir-App/Template, release v1.0 | tree `d7568ebb416e510696a7fc0f5f89a86402ceb6dc851ad4dfeb897e5d9b128d10` | per library (MoltenVK Apache-2.0, SDL zlib, gnutls LGPL, freetype FTL/GPL-2) | Sikarugir |
| GStreamer.framework | from Template-1.0.24 | same | tree `33d20e3dbca70e3890b9e2bccf7e4386b12b5b1a72085519604390f73967dda8` | LGPL | Sikarugir |
| DXMT (`dxmt`) | v0.80-244-g7c8dee1 | Template-1.0.24 | tree `dc2158758a80b4256db6dd7a36bc6cd263442dec3c460829b8fe6e0bda159469` | LGPL-2.1-or-later (3Shain/dxmt) | Sikarugir build; renders D3D10/11 |
| DXVK (`dxvk`) | DXVK-Sikarugir-async-v1.10.3 + D9VK-Sikarugir-v2.3 | Template-1.0.24 | tree `4f9bfaa4a162a4c4913c53d1e5fc97e7711687e572a7757b6fd255d820353e27` | zlib | Sikarugir build; the only D3D9 path that works on this MoltenVK |
| DXVK 3 (`dxvk3`, `d9vk`) | DXVK-Sikarugir-v3.1.1-async | Template-1.0.24 | trees `c5803dcdc37e85a3729e528ab408ab54fedbfa78759a0ce40771674d8cceec2a`, `6c60009d88e3e1b92c1173026b484ec57c327659a039676543e3d736a2e3a290` | zlib | installed, never loaded (MoltenVK lacks its required features) |
| cnc-ddraw (`cnc_ddraw`) | cnc-ddraw-v7.1.0.0 | Template-1.0.24 | tree `c054c05a28dd5a4bad4603ce12c1f988003393faa110f7d0141e7758a065bebf` | MIT (FunkyFr3sh/cnc-ddraw) | Sikarugir copy; 32-bit only |
| Wine Mono | 9.4.0 | dl.winehq.org/wine/wine-mono/9.4.0/ (same bytes as github.com/madewokherd/wine-mono) | SHA-256 `cf6173ae94b79e9de13d9a74cdb2560a886fc3d271f9489acb1cfdbd961cacb2` | MIT + per-component | official upstream; installed into each new bottle |
| .NET probe `netprobe.exe` | — | ours: `Resources/netprobe.cs`, built by `tests/stress/build-netprobe.sh` | SHA-256 `5c3d94fafce2b95c4e23006f505934b2ff94f29707dfec98f3e7d410499ecd8d` | ours | — |
| D3DMetal | 3.0 | your own Game Porting Toolkit 3.0 disk image | licence acceptance = SHA-256 of its `License.rtf` | Apple's licence | never downloaded by Cosmopolitan |
| Sparkle | 2.10.0 | github.com/sparkle-project/Sparkle (SwiftPM `exact: "2.10.0"`) | SwiftPM resolved revision | MIT | app dependency |

Every installed driver folder and GStreamer is byte-identical to Template-1.0.24 (tree hashes compared on 2026-10-23).

## What changed with the pins

- The weekly job no longer downloads the Sikarugir template or newer Sikarugir engines. It checks the DXMT and DXVK upstream releases and only reports them. Drivers › Update… replaces a driver only after you confirm, and keeps the previous one as `<name>.old`.
- First-run setup downloads only Template-1.0.24 (not "newest") and only engine 10.0_8, each verified against the pins above. The template archive also contains Apple's D3DMetal (folders `d3dmetal` and `apple_gptk`). Those folders are excluded while extracting, so D3DMetal never lands on disk; the archive's bytes still pass through the download.
- A driver folder that goes missing is restored from the verified local template, not from a newer upstream release.
- Already on your disk: `~/Library/Application Support/Sikarugir/Template/Template-1.0.24.app` still holds Sikarugir's copy of D3DMetal, fetched earlier by the old weekly job or setup. Cosmopolitan doesn't use it. Removing that folder is your call, because Sikarugir's own app may manage this location.

## In progress: Cosmos, Cosmopolitan's own engine (not installed by the app yet)

| Component | Version | Source | Pin | Licence | Status |
|---|---|---|---|---|---|
| Cosmos (Wine 11) | `cosmos-11.0-r<N>` | github.com/cyber-prinzesse/cosmos-engine (`build.yml`, `cosmos_revision`) | tarball SHA-256 in each build's `.sha256`; `COSMOS-BUILD.txt` lists source pin, patches, commit | LGPL-2.1-or-later (Wine) | Wine 11 for macOS + Highball's series + Cosmopolitan's 0028–0031 and theme; bundles its own host libraries. Test builds only; see `docs/adr/0001-cosmos-engine.md` |

## Upstream replacements (not installed; each needs to pass the suite first)

| Component | Official source | Licence |
|---|---|---|
| Wine for macOS | github.com/Gcenx/macOS_Wine_builds ("Official Winehq macOS Packages") | LGPL-2.1-or-later |
| MoltenVK | github.com/KhronosGroup/MoltenVK | Apache-2.0 |
| DXMT | github.com/3Shain/dxmt | LGPL-2.1-or-later |
| DXVK / DXVK-macOS | github.com/doitsujin/dxvk, github.com/Gcenx/DXVK-macOS (D3D10/11 only; D3D9 removed) | zlib |
| cnc-ddraw | github.com/FunkyFr3sh/cnc-ddraw | MIT |
| GStreamer | gstreamer.freedesktop.org/download | LGPL |
| SDL | github.com/libsdl-org/SDL | zlib |

Known gap: upstream has no replacement yet for the "D9VK-Sikarugir-v2.3" D3D9 build, the only working DXVK D3D9 path here. Wine's own D3D9 renders too (measured), so it is the fallback.
