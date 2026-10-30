# Design: compatibility gate, repair, chip matrix, conflict and crash tests

Status: **decisions of 2026-10-23 applied** (D1–D4 below). Parts are now implemented and tested: the safety fixes, pinned components and
runtimes, the D3DMetal version guard, the honest battery cap, and the C++ decision engine (not yet wired into launches). It builds on
`docs/phase0-report.md`; the component list with sources is `docs/components.md`.
Everything ships behind a feature flag: UserDefaults `compatGate` (default off) and `COSMO_COMPAT_GATE=1` for the CLI and the test build. With the flag off, today's behaviour stays.

Conventions: hardware and OS claims carry **[V n]** (verified, numbered source at the end) or **[U]** (unverified).
"Measured" means I ran it on this Mac (M2 Max, 32 GB, macOS 27.0.1) during Phase 0.

---

## 0. What I propose, and what I need you to decide

1. **One decision engine** that turns `GameProfile + HostProfile + Inventory + CompatDB + Pins` into a `Decision` with a human-readable trace. It is a pure function, unit-tested with mocked hosts.
   Recommendation: write it in the new C++ core from day one, since Phase 5 wants it there anyway. Its boundary is one JSON-in/JSON-out C function.
2. **Untrusted parsing moves out of the app process** into a small C++ helper, `cosmo-probe`, run as a subprocess with a timeout. It covers PE, AVX scan, MoltenVK features and hashes. A crash there can't take down the app or interrupt a repair.
3. **Capability checks replace version blacklists**:
   - DXVK is allowed when the installed MoltenVK reports DXVK's required Vulkan features;
   - D3DMetal's features (frame cap, Metal 4 backend switch) are read from the framework itself;
   - Rosetta's AVX2 support is tested by running a tiny AVX2 program once.
4. **Transactional repair**: stage → verify → atomic swap with `renamex_np(RENAME_SWAP)`, a journal, per-prefix `flock` locks, per-prefix last-known-good snapshots, and side-by-side backend versions.
5. **The crash suite runs only in a test build plus throwaway prefixes**. Each test gets a fresh APFS clone of a pre-booted golden prefix, plus a tripwire that fails the run if your real data changes.

Decisions for you:
- **D1, interception of launches from Steam's own window** (§3.1): **decided 2026-10-23: pre-configure and watch only; no launch-option wrapper yet.**
- **D2, decision engine language**: **decided: C++ from the start**, with a boundary of plain C structs and enums (not JSON). Implemented as `cosmo_decide()` in `Sources/Native/decide.cpp`; `tests/native/decide_test.cpp` covers every row under ASan + UBSan.
- **D3, Wine Mono and redistributables**: **decided and implemented**: Wine Mono 9.4.0 from WineHQ, Visual C++ v14 14.51.36247.0 (x86/x64) and DirectX June 2010 from Microsoft, pinned by version and SHA-256, downloaded at setup, nothing bundled. The .NET Framework 4.8 installer is not used: Wine Mono is the .NET runtime here.
- **D4, provenance**: **decided**: the Sikarugir engine and drivers stay, pinned (engine tarball SHA-256, template parts by tree hash), until upstream replacements pass the suite. The weekly Sikarugir template download is gone; D3DMetal comes only from your own GPTK install.

## 1. What "driver" means here, and backend coverage

On macOS the GPU driver ships with the OS. Here, "driver" means three things:
1. **Graphics translation backends**: D3DMetal (yours, from Apple's Game Porting Toolkit), DXMT, DXVK + MoltenVK, vkd3d-proton + MoltenVK, cnc-ddraw, wined3d (OpenGL).
2. **Windows runtime components in the prefix**: VC++ redistributables, d3dcompiler/d3dx, .NET or Wine Mono, XAudio.
3. **The Wine build.**

### 1.1 Coverage table

| Backend | DirectDraw | D3D8 | D3D9 | D3D10 | D3D11 | D3D12 | 32 / 64-bit | Translates to |
|---|---|---|---|---|---|---|---|---|
| D3DMetal (GPTK 3.0, 4.x) | — | — | — | not stated | DX11 per a vendor support note [U B1]; Apple's Read Me doesn't list APIs | DX12 translation layer [V R3, R4] | 64-bit only (measured: no i386 DLLs in 3.0 or 4.0b3) | Metal; Metal 4 backend in 4.0 beta, default on macOS 27 [V R4] |
| DXMT | — | — | — | yes [V B3b] | yes [V B3] | — | both; 32-bit via WoW64 build [V B3b] | Metal [V B3] |
| DXVK upstream | — | yes | yes | yes | yes [V B4] | — | both [V B4] | Vulkan; ≥ 2.7 can't run on stock MoltenVK (§3.4) |
| DXVK-macOS (Gcenx) | — | — | removed in 1.10.3-repack [V B5b] | yes | yes [V B5] | — | both [V B5c] | Vulkan via MoltenVK [V B5] |
| vkd3d-proton | — | — | — | — | — | yes [V B6] | both [V B6] | Vulkan; **can't create a device on stock MoltenVK** (§3.4) [V B19, B23] |
| Wine's d3d12 + vkd3d | — | — | — | — | — | yes, through `vulkan-1.dll` [V B7] | not checked [U] | Vulkan; untested on MoltenVK [U] |
| cnc-ddraw | yes [V B8] | — | — | — | — | — | we ship 32-bit only (measured) | GDI, OpenGL or D3D9 as its output [V B8] |
| wined3d (Wine's own) | yes | yes | yes | yes | yes [V B9] | — | both | OpenGL or Vulkan renderer [V B9b]. macOS OpenGL is deprecated [V B10]; the 4.1 ceiling is documented only for Intel Macs [V B11] |

Measured on this Mac:
- the D3D9 build that works is "D9VK-Sikarugir v2.3" (Sikarugir-only);
- DXVK-Sikarugir v3.1.1 finds no adapter;
- DXMT renders D3D10/11 in both bitnesses;
- D3DMetal 3.0 renders D3D12;
- cnc-ddraw renders 32-bit DirectDraw.

## 2. Architecture

```
            ┌──────────── Swift (app + CLI) ─────────────┐        ┌──── C++ core (libcosmo) ────┐
 UI sheet ──┤ LaunchGate ──► DecisionEngine (C ABI, JSON) ├───────►│ decide()  pure, no I/O       │
 CLI flags ─┤   ▲    │                                    │        │ repair engine, journal, lock │
            │   │    └──► RepairEngine (C ABI) ───────────┼───────►│ sha256, staging, swap        │
            │ HostProbe (Metal, sysctl, IOKit, Rosetta)   │        └──────────────────────────────┘
            │ Inventory (versions, SHA-256, capabilities) │        ┌──── cosmo-probe (subprocess) ─┐
            │ OutcomeRecorder (JSONL)                     ├──JSON──┤ PE, .NET header, AVX scan,    │
            └─────────────────────────────────────────────┘        │ MoltenVK features, hashing    │
                                                                   └───────────────────────────────┘
```

- **Swift keeps**: UI, Metal device queries, IOKit power, process launching, the flag.
- **C++ core (in-process)** gets only code that never touches untrusted bytes: the decision engine, transaction bookkeeping, hashing of our own staged files.
- **`cosmo-probe` (out-of-process)** gets everything that reads files a game or download controls.

## 3. Feature 1: the compatibility gate

### 3.1 Interception

| Path | How | Can it change drivers/env before the game starts? | Trade-offs | Feasible |
|---|---|---|---|---|
| (a) Cosmopolitan UI/CLI | gate runs inside `Model.launch` before `prepare()`; Steam games then start with `steam.exe -applaunch <appid>` (today, `SteamLaunch.swift:4-10`) or `steam://rungameid/<appid>` | yes; a driver-set change restarts Steam (today, `Start.swift:12-16`) because Steam games inherit Steam's environment | `-applaunch` needs only the running Steam; `steam://` needs Steam's URL handler registered in the prefix | **yes** |
| (b1) per-game launch-option wrapper | Steam launch options `C:\cosmo\gate.exe %command%`; `gate.exe` asks the app for a decision, then starts the game | yes, per game | the Windows client parses `%command%` (Valve fixed "crash for some uses of %command%" in 2023 [V B32]) but no Valve doc describes substitution on Windows [U]; means editing Steam's `localconfig.vdf` with Steam closed (a Steam file, so it needs your OK) | to prove with the fake-Steam harness, then a real test with your OK |
| (b2) watch process creation | `kqueue EVFILT_PROC` on Steam's pid tree, or the existing 1 s `cosmo_proc_find` poll | no; the game is already running | good for recording outcomes and warnings; killing and relaunching would be bad UX | yes, record-only |
| (b3) watch appmanifests | FSEvents on `steamapps/appmanifest_*.acf`: install, update, `StateFlags` | yes: runs the gate after an install or update, before you press Play | flag meanings come from a reverse-engineered header, not Valve: FullyInstalled 4, UpdateRequired 2, UpdateRunning 256, UpdateStarted 1024, AppRunning 8192 [V B34, RE source]; can't see per-launch choices | **yes** |
| (b4) pre-configured bottle state | per-exe `AppDefaults` registry keys plus the bottle's driver set, kept correct by (b3) | yes: Wine applies `AppDefaults` to every process, whoever starts it | per-exe keys must become owned and cleaned up (Phase 0 N3) | **yes** |

**Decided (D1, 2026-10-23): (a) + (b3) + (b4), with (b2) for learning. No launch-option wrapper (b1) yet.** Today (b3) exists as the folder watcher on `steamapps` (a change triggers a scan and the launch checks), and (b4) only for programs that were launched once through Cosmopolitan, because registry settings are written at launch. Writing them ahead of time from the launch checks is part of the Feature 1 implementation.

### 3.2 Game probe (`cosmo-probe game <exe>` → JSON)

| Field | How | Unreadable / failure |
|---|---|---|
| `arch` | PE `Machine`: 0x14c x86, 0x8664 x64, 0xaa64 arm64 | `"unreadable executable"`; never a guess |
| `imports` | normal + delay-load import names, bounds-checked (fixes Phase 0 N7) | empty list + error code |
| `graphics` | imports + runtime-loaded D3D names in the exe and its large engine DLLs (today's `graphicsAPIs`) | as found |
| `dotnet` | CLI header present → metadata version string (`v2.0.50727` / `v4.0.30319`); `<supportedRuntime>` and `TargetFramework` from `<exe>.config` if present | `null` = not .NET |
| `anticheat` | known files and folders (EAC, BattlEye, kernel drivers, today's `AntiCheat.swift`) + CompatDB | kernel anti-cheat = **hard blocker**, never repaired |
| `avx` | CompatDB first; else VEX/EVEX counts from the scan (today's `avxscan.cpp`) | `unknown` |
| `sha256`, `size`, `mtime` | for cache keys and non-Steam DB keys | — |

Limits: 30 s wall clock and 512 MB address space (`setrlimit` in the child). Files over 2 GiB are refused with a clear result, which fixes the whole-file reads of Phase 0 §8.

### 3.3 Host probe (Swift → `HostProfile` value)

| Field | API | Notes |
|---|---|---|
| chip name, `hw.model` | `sysctl machdep.cpu.brand_string`, `hw.model` | display and known-issue lookup only |
| RAM | `sysctl hw.memsize` | |
| macOS | `ProcessInfo.operatingSystemVersion` | |
| power | `IOPSCopyPowerSourcesInfo` (exists: `cosmo_on_battery`) | |
| thermal | `ProcessInfo.thermalState` | live, not a model table |
| GPU family | `MTLDevice.supportsFamily(.apple7 … .apple10)` | Apple9+ = hardware RT intersector [V 38], Dynamic Caching [V 38] |
| ray tracing API | `MTLDevice.supportsRaytracing` | true from Apple6 up, so not a hardware-RT signal [V 1, 35] |
| GPU memory budget | `MTLDevice.recommendedMaxWorkingSetSize` | "an approximation of how much memory … without affecting runtime performance" [V 36] |
| Rosetta | `arch -x86_64 /usr/bin/true` exit code (installed and runnable) | after an upgrade to macOS 27 Rosetta "is not automatically restored" [V 45] |
| Rosetta AVX2 | run `avx2probe.exe`, a tiny AVX2 test exe, once per macOS build; cache the result | capability, not a version check |
| backends | per folder: version, SHA-256 of every DLL, capability manifest | |
| D3DMetal | `CFBundleShortVersionString` (beta = contains `b`), feature flags from the framework's own `D3DM_*` names (`D3DM_MAX_FPS` → frame cap, `D3DM_MTL4` → Metal 4 switch), licence hash | measured: 3.0 lacks both, 4.0b3 has both |
| MoltenVK features | `cosmo-probe vulkan`: links the engine's Vulkan loader + MoltenVK ICD, calls `vkGetPhysicalDeviceFeatures2`/`Properties2` and the extension list → JSON | runs out of process because a driver bug must not crash the app |

`HostProfile` is a plain value. Tests build it by hand (M1 Air 8 GB macOS 15 battery, M5 Ultra, A18 Pro 8 GB, …).

### 3.4 Capability rules instead of blacklists

Each backend version ships a small requirement manifest. The engine checks it against `HostProfile`:

```json
{ "backend": "dxvk", "version": "3.1.1",
  "requires": { "vulkan_api": "1.3", "features": ["shaderCullDistance", "geometryShader", "..."], "extensions": ["..."] },
  "provides": { "x86": ["d3d9", "d3d10", "d3d11"], "x64": ["d3d9", "d3d10", "d3d11"] },
  "source": "<release URL>", "sha256": { "x64/d3d11.dll": "…" }, "license": "zlib" }
```

- DXVK made required features a hard adapter check in **v2.7** (commit `5a4d892`, July 2025): devices lacking them "will no longer be listed as DXGI / D3D9 adapters" [V B12, B13]. The check is still there at v3.1.1 [V B16b].
- At v3.1.1 the list is long [V B16]. It includes Vulkan 1.3, `geometryShader`, `shaderCullDistance`, `robustBufferAccess2`, `nullDescriptor`, `VK_KHR_maintenance5/6` and more. The full list goes into the manifest verbatim.
- Stock MoltenVK sets `maxCullDistances = 0; // unsupported`, never sets `geometryShader`, and reports `robustBufferAccess2 = false`, `nullDescriptor = false` [V B19].
- That matches the measurement: DXVK-Sikarugir v3.1.1 logs "Skipping: Device does not support required feature 'shaderCullDistance'".
- Open question: DXVK checks `geometryShader` first [V B16], so the Sikarugir MoltenVK must report it [U]. `cosmo-probe vulkan` will show the real feature set.
- vkd3d-proton refuses devices without robustness2, `nullDescriptor` and transform feedback [V B23], none of which stock MoltenVK has [V B19, B24]. The manifest makes it ineligible here, with that reason.
- **Measured on this Mac's own Vulkan driver** (the engine's `libvulkan.1.dylib` + `libMVK.dylib`, MoltenVK 1.4.1 on the Apple M2 Max, API 1.3.334; probe `tests/native/vkprobe.c` built against Khronos Vulkan-Headers 1.4.309): `geometryShader=0 shaderCullDistance=0 robustBufferAccess2=0 nullDescriptor=0 transformFeedback=0`, `VK_EXT_transform_feedback` absent. So DXVK ≥ 2.7 and vkd3d-proton both fail their device checks here, as sourced above.
- When a future MoltenVK reports the feature, DXVK 3 becomes eligible with no code change.
- `driverUsable()`'s regex (`Drivers.swift:13`) is deleted once this passes the regression test in §6.

### 3.5 Windows version selection

Invariants, enforced after every other rule and tested:
1. 64-bit PE (`0x8664`) → never `win95/win98/winme/win2k/winxp`. 64-bit Windows started with XP x64. Minimum `winxp64`, default `win10`.
2. .NET with CLR `v4.0.30319` → at least `win7`. .NET Framework 4.6.2–4.8.1 list Windows 7 SP1 as the oldest client OS [V 70]. CLR `v2.0.50727` → at least `winxp` [U].
3. Installers → no era treatment (today).
4. Era heuristics (`LaunchCheck.swift:33-49`) only lower the version for 32-bit native programs and never below the invariants.
5. Per-exe keys become **owned**: written under a name that includes the game's identity and recorded in `options/.owned-keys`, removed on uninstall or rule change. This fixes Phase 0 N3. A stale `win98` from an earlier rule is cleaned up at the next preflight.

### 3.6 Decision

**Precedence**: hard blockers > per-game pin > CompatDB known-good > capability heuristic > global default.
A global pin, for example "DXVK for everything", counts as the global default. It is never edited by the engine.

**Decision table** (first matching row wins; every row writes a trace line):

| # | Condition | Outcome |
|---|---|---|
| 1 | kernel anti-cheat detected | **block**: "This game's anti-cheat runs in the Windows kernel; it can't run here." No repair offered. |
| 2 | Rosetta missing or not runnable, x86 program | **block** + guide: "Install Rosetta: `softwareupdate --install-rosetta`" (you run it; it's a system change) |
| 3 | AVX2 needed and the Rosetta AVX2 probe failed | **block** + reason |
| 4 | AVX-512 only (EVEX code paths with no fallback known in the DB) | **warn**: Rosetta never executes AVX-512 [V 39] |
| 5 | required API has no eligible backend for this arch (e.g. D3D12 32-bit, D3D12 without D3DMetal) | **hard incompatibility** → ranked alternatives (§5 scenario A) |
| 6 | per-game pin set and the pinned backend serves the API | use the pin |
| 7 | per-game pin set but can't serve the API | **ask** (GUI) / exit 3 (CLI): proposal + reason; pin untouched unless you accept |
| 8 | DB known-good entry whose backend@version is installed and eligible | use it |
| 9 | DB known-good backend installed at a different version, and that version failed here (outcome log) | propose side-by-side rollback to the known-good version (§5 scenario C) |
| 10 | capability heuristic (today's `driverPlan` with capability checks) | use it |
| 11 | global default | use it |

Soft warnings attach to any row: RAM below the game's DB minimum or `recommendedMaxWorkingSetSize` budget, RT enabled by default on a GPU without hardware RT, fanless model under sustained load, battery cap inactive (§3.10), macOS 28+ Rosetta policy (§4).

**CLI**: `cosmopolitan --launch <bottle> <exe> [--auto-fix | --no-auto-fix] [--json]`.

| Exit code | Meaning |
|---|---|
| 0 | started |
| 2 | blocked by a hard blocker |
| 3 | proposal needs a decision (no flag given) |
| 4 | repair failed and rolled back |
| 5 | probe failed (no guess made) |
| 6 | prefix locked by another repair |

**GUI**: a sheet with the proposal, the reason in one sentence, ranked options and "Details" (the trace). Accepting writes a per-game override with the reason and date.

**CompatDB**: `Resources/compat-db.json` ships with the app; `support/compat/local.json` holds learned outcomes and your overrides.

```json
{ "schema": 1, "db_version": "2026.10.22-1",
  "games": { "steam:3751260": {
      "name": "The Blood of Dawnwalker", "apis": ["d3d12"], "arch": "x64",
      "requires": { "avx2": true, "min_macos": "26.0", "ram_gb": 16 },
      "backends": { "d3dmetal": { "status": "known-good", "versions": ">=3.0" },
                    "vkd3d-proton": { "status": "broken", "note": "…" } },
      "known_issues": [ { "id": "upscaler-dlss-lag", "text": "Use FSR, not DLSS, under D3DMetal",
                          "affects": { "backend": "d3dmetal" } } ],
      "last_known_good": { "backend": "d3dmetal@4.0b3", "wine": "10.0_8", "date": "2026-10-22", "outcome": "clean>300s" } } },
  "exe": { "sha256:…": { "…": "non-Steam programs keyed by executable hash" } } }
```

### 3.7 Repair and fetch

- **Component manifest** (one per backend version and runtime): name, version, official source URL, SHA-256 per file, licence, provenance note. Nothing installs without a matching hash.
- **Sources**: official upstream releases only; a local cache in `support/cache/<sha256>`; downloads are verified before staging and the cache is kept on failure (test 2).

| Component | Official source | Licence |
|---|---|---|
| Wine for macOS | github.com/Gcenx/macOS_Wine_builds ("Official Winehq macOS Packages") [V B35]; WineHQ's own link to it [U] | LGPL-2.1+ [V B36] |
| MoltenVK | github.com/KhronosGroup/MoltenVK releases | Apache-2.0 [V B37] |
| DXMT | github.com/3Shain/dxmt releases | LGPL-2.1+ [V B38] |
| DXVK / DXVK-macOS | github.com/doitsujin/dxvk, github.com/Gcenx/DXVK-macOS | zlib [V B4, B5c] |
| vkd3d-proton | github.com/HansKristian-Work/vkd3d-proton | LGPL-2.1 [V B6] |
| cnc-ddraw | github.com/FunkyFr3sh/cnc-ddraw | MIT [V B8] |
| GStreamer | gstreamer.freedesktop.org/download (.pkg framework) | LGPL [V B39, B40] |
| SDL | github.com/libsdl-org/SDL | zlib [V B41] |
| Wine Mono | dl.winehq.org/wine/wine-mono/ | mixed, per component [V B42] |
| VC++ v14 redistributable | aka.ms/vc14/vc_redist.x86.exe and .x64.exe | Microsoft terms; "Redistribution is permitted only for licensed Visual Studio users" [V B43], so Cosmopolitan downloads it on your request and never bundles it |
| DirectX End-User Runtime (June 2010) | microsoft.com/download id 8109 | not stated on the page [V B44] |
| .NET Framework 4.8 offline | go.microsoft.com/fwlink/?linkid=2088631 | not stated on the page [V B45] |

No upstream release exists today for the Sikarugir-only pieces that make D3D9 work here (the "D9VK-Sikarugir v2.3" build, a MoltenVK that passes DXVK's `geometryShader` check). Replacing them under your rule needs a tested alternative first (decision D4).
- **Windows runtimes** come from the vendors' official installers (VC++, DirectX June 2010, .NET), run in the prefix with their own licence prompt where they have one.
- **D3DMetal is never downloaded.**
  - When missing: "Direct3D 12 needs Apple's D3DMetal. Download the Game Porting Toolkit from Apple (Apple Account required) [V 51], then choose its disk image here." After that, re-detect.
  - When you point at a DMG (mounted or not, fixed this session) the installer reads the incoming version and feature flags first. If it is older than or missing features of the installed one, it shows:
    "This replaces D3DMetal 4.0b3 with 3.0. You lose: the Metal 4 backend switch, the 60 fps battery cap for Direct3D 12. 4.0b3 will be kept as a backup. Replace?"
  - The current version is moved to `renderer/d3dmetal@<version>` before the swap and never deleted. Licence acceptance is per version (hash of that version's licence file).
  - The sidebar and Drivers menu show "D3DMetal 4.0 beta 3" / "D3DMetal 3.0".

### 3.8 Transactions

```
 Idle ──lock──► Locked ──► Staging ──► Verifying ──► Swapping ──► Committed ──unlock──► Idle
                  │           │            │             │
                  └──────────►└───────────►└────────────►└──► RollingBack ──► RolledBack ──unlock──► Idle
 On start: journal entry without Committed/RolledBack → resume: before Swapping = discard staging; in Swapping = swap back from backup
```

- **Lock**: `<prefix>/.cosmo.lock`, opened `O_CREAT|O_CLOEXEC` and held with `flock(LOCK_EX|LOCK_NB)`, plus JSON {pid, process start time, purpose} for messages.
  - `O_CLOEXEC` matters: `flock` locks are shared by duplicated descriptors [V 72], so a Wine child that inherited the descriptor would keep the lock alive.
  - Release on process death is standard BSD behaviour; test 8 proves it with SIGKILL.
- **Journal**: `support/journal/<txid>.jsonl`, append-only, `fsync` after each line: `begin`, `staged {paths, sha256}`, `verified`, `swap {target, backup}`, `committed`.
- **Atomic swap**: `renamex_np(staged, target, RENAME_SWAP)` atomically swaps two paths, even a file with a directory, on volumes reporting `VOL_CAP_INT_RENAME_SWAP` [V 71]. Check the capability first; otherwise refuse rather than fall back to a non-atomic copy.
- **Registry and overrides**: applied as one `.reg` import while the prefix's wineserver is stopped. Undo = restore the prefix's last-known-good APFS clone (existing snapshot code, `Snapshots.swift`).
- **Last-known-good per prefix**: the snapshot taken before the first change of a transaction, kept until the next clean launch.
- **Side by side**: `renderer/<name>@<version>/`. The decision stores `name@version`, so two games can use two DXVK versions.
- **Re-entrancy**:
  - no lazy global may do I/O or wait (the d3dmetalOK bug);
  - licence and installation state live in one actor-isolated `InstallState` that is read as an immutable snapshot;
  - background checks hold no locks while waiting on child processes;
  - a test repeats the old crash pattern under concurrent checks (§6, test 17a).

### 3.9 Learning

- `support/compat/outcomes.jsonl`, one line per launch: game key, backend@version, Wine build, `HostProfile` hash, start/exit time, exit code, classification, and the first matching log signature.
- Classification:
  - `clean`: ran ≥ 300 s, or you quit it;
  - `early-crash`: exit ≠ 0 within 60 s;
  - `crash`: exit ≠ 0 later;
  - `hang`: watchdog;
  - `blocked`.
- A `clean` run updates last-known-good. An `early-crash` marks that combination failed for this host and offers the next candidate. At most **2 automatic retries** per launch, then the gate asks.

### 3.10 Battery frame cap

Findings:
- D3DMetal 4.0 beta documents `D3DM_MAX_FPS`: "caps the application's frame rate to the specified frames per second" [V R4]. The 3.0 Read Me has no such setting [V R3], and the 3.0 framework has no such string (measured).
- No other documented external mechanism exists [B research]:
  - the Metal HUD only displays [V B27];
  - `CAMetalLayer.displaySyncEnabled` is an in-app property [V B28];
  - Game Mode raises priority [V B30];
  - Low Power Mode makes no frame-rate statement [V B31].
- Lowering the display refresh rate works only on some displays [V B29], only if D3DMetal presents with vsync (undocumented [U]), and it's a system setting we don't change.
- An in-process limiter would mean hooking D3DMetal's DXGI Present. That modifies how Apple's component runs, so it's not proposed.

Apple's Read Me text, quoted exactly:
- Frame cap, 4.0 beta 2 Read Me line 52: "D3DM_MAX_FPS - Unset by default. Setting this environment variable caps the application’s frame rate to the specified frames per second." [V R4]
- Metal 4 backend, same file line 50: "D3DM_MTL4 - On macOS 27 or later, the Metal 4 backend for D3DMetal’s DirectX 12 translation layer is enabled by default (1, ON). Setting this environment variable to 0 (OFF) disables the Metal 4 backend and uses the Metal 3 backend." [V R4]
- 16 GB, line 10 of both Read Mes: "Translated games require more resources, so developer-focused Macs with 16GB of RAM or more are recommended." [V R3, R4]
- The 3.0 Read Me contains neither D3DM_MAX_FPS nor D3DM_MTL4 (0 matches). [V R3]

Rule (implemented): the cap is a capability of the active backend (§3.3 feature flags).
- With it: set it.
- Without it: the launch note and tile say "Battery 60 fps cap: not available for this game (D3DMetal 3.0 has no frame limiter). Use the game's own frame limit or vsync."

Today the app logs "60 fps cap … active" for every backend (`LaunchEnvironment.swift:26-28`), which is wrong for D3D12 on 3.0.

## 4. Feature 2: behaviour per chip

Source: Apple newsroom, support tech specs and Metal docs, collected by the hardware research. "API" = Metal API available without hardware acceleration.

| Chip | HW ray tracing | Dynamic Caching | Mesh shading | Smallest RAM | Metal family | Fanless Mac |
|---|---|---|---|---|---|---|
| M1 / Pro / Max / Ultra | no [V 14] | no [V 14, 38] | API only [V 1, 14] | 8 GB (M1) [V 3] | Apple7 [V 1] | MacBook Air M1 [V 56] |
| M2 / Pro / Max / Ultra | no | no | API only | 8 GB (M2) [V 9] | Apple8 [V 1] | MacBook Air M2 [V 57, 58] |
| M3 / Pro / Max | gen 1 [V 14] | gen 1 [V 14] | hardware [V 14] | 8 GB (M3) [V 15] | Apple9 [V 1, 34] | MacBook Air M3 [V 59] |
| M3 Ultra | yes [V 17] | yes [V 17] | hardware [V 17] | 96 GB [V 17] | Apple9 | — |
| M4 / Pro / Max | gen 2 [V 20]; Pro/Max "2x faster" [V 22] | yes [V 19] | hardware gen 2 [V 19, 20] | 16 GB [V 21] | Apple9 [V 34] | MacBook Air M4 [V 60] |
| M4 Ultra | not announced [U] | | | | | |
| M5 | gen 3 [V 24] | gen 2 [V 24] | not stated [U] | 16 GB [V 25] | Apple10 [V 1] | MacBook Air M5 [V 61] |
| M5 Pro / Max | gen 3 [V 26] | gen 2 [V 26] | hardware [V 26] | 24 / 36 GB [V 27] | Apple10 | — |
| M5 Ultra | gen 3 [V 28] | gen 2 [V 28] | hardware [V 28] | 96 GB [V 29] | Apple10 | — |
| M6 | yes, generation not stated [V 28] | "updated" [V 28] | not stated | 16 GB [V 31] | not in Apple's May 2026 tables [U] | — |
| **MacBook Neo**: Apple A18 Pro, an iPhone-class chip, not M-series | yes [V 32] | not stated | not stated | 8 GB only, no other option [V 32] | Apple9 [V 1] | yes, no fan [V 33] |

Neural Accelerators in GPU cores: M5 family [V 24, 26, 30] and M6 [V 28]; earlier chips not listed (inference [U]).

**Defaults derived from capabilities, not chip names:**
- **Ray tracing**: GPU family below Apple9 → suggest turning in-game RT off. The Metal RT API works there without hardware acceleration [V 1, 37, 38], so this is a performance tip, never a blocker.
  - Apple's own D3DMetal does the same split: `D3DM_SUPPORT_DXR` "Defaults to 0 (OFF) on M1 & M2 Macs, and to 1 (ON) for M3 & later Macs" [V R3]. Cosmopolitan leaves that default alone.
- **Memory**: warn on 8 GB, or when the DB's game minimum exceeds `recommendedMaxWorkingSetSize`. Apple's GPTK Read Me says "developer-focused Macs with 16GB of RAM or more are recommended" [V R3, R4].
- **AVX/AVX2**: Rosetta "translates all x86_64 instructions, including ones from the AVX and AVX2 instruction set, but it doesn't support … AVX512" [V 39].
  - Apple's GPTK Read Me ties advertising AVX to macOS 15: "`ROSETTA_ADVERTISE_AVX` … On macOS 15 Sequoia and later … causes the CPU instruction translation layer to publish cpuid information … This setting does not modify the availability of the instruction set" [V R3]. So the variable Cosmopolitan sets (`LaunchCheck.swift:88`) is documented, and it only changes what games detect.
  - The runtime AVX2 probe still decides, because it also catches a missing or broken Rosetta.
- **Rosetta horizon**: Rosetta stays general-purpose "through macOS 27"; afterwards Apple keeps "a subset … aimed at supporting older unmaintained gaming titles, that rely on Intel-based frameworks" [V 39, 43].
  - Rosetta stays fully available on macOS 26 and 27. What changes at the macOS 27.0 upgrade is only whether it is installed: "If Rosetta was previously installed, it is not automatically restored after upgrading to macOS 27.0." (macOS 27 release notes, Deprecations, 163213094) [V 45]. A Mac that had Rosetta before the upgrade comes out without it, so Wine can't start until it is installed again. The host probe's Rosetta check (§3.3) and decision row 2 catch exactly this.
  - Whether Wine-hosted games and their non-game helper processes qualify is unknown. Apple staff only said macOS x86 games keep working [V 46].
  - macOS 27 betas have `game-test-tool` to try the macOS 28 behaviour [V 45].
  - The architecture layer stays isolated (one place starts x86 processes), and the UI warns on macOS 28+ without promising support.
- **D3DMetal versions**: GPTK 4 is the current download on Apple's page [V 51].
  - The 4.0 beta Read Me documents a Metal 4 backend for D3DMetal's DirectX 12 layer, on by default on macOS 27, and the `D3DM_MAX_FPS` cap [V R4]. The 3.0 Read Me documents neither [V R3]. So your note holds for D3DMetal itself.
  - Apple's WWDC25 line that GPTK 3 "adds support for Metal 4" [V 50] refers to the toolkit, not this backend [U].
  - Both Read Mes require "macOS 15 Sequoia or higher" [V R3, R4].
  - Both versions stay supported through the feature flags in §3.3.
- **Thermals**: fanless models [V 56–61, 33] get a "sustained load may slow down" note when `thermalState` reaches `.serious`. Third-party throttling numbers [U] are not used. Performance tier only, never a verdict.

## 5. Feature 3: conflict scenarios

Each scenario is a unit test (mock `HostProfile` + fake inventory + DB fixture) and, where marked, an integration test in a throwaway prefix.

**A. M1 Air 8 GB, macOS 15, D3D12 + AVX2 game, RT on after an update, global pin DXVK, DB: D3DMetal known-good but GPTK missing, vkd3d-proton broken.**
- Trace: row 5 fires (D3D12, no eligible backend: the global DXVK pin has no D3D12, D3DMetal not installed). Row 3 is checked with the cached AVX2 probe.
- Sheet text: "This game needs Direct3D 12. Your default, DXVK, doesn't support Direct3D 12, and Apple's D3DMetal isn't installed."
  1. **Install Apple's Game Porting Toolkit, then use D3DMetal** (recommended; known to work for this game)
  2. Try vkd3d-proton (experimental; marked broken for this game). On stock MoltenVK this option is shown greyed out with its reason, "vkd3d-proton can't run on this Mac's Vulkan driver (no robustness2)" [V B19, B23]. It becomes selectable only if the probe reports the features.
  3. Cancel
- Warnings: "This Mac has 8 GB of memory; the game may stutter." "Ray tracing is on in this game's settings and this GPU has no hardware ray tracing: turn it off in the game."
- Result: a per-game override `{ backend: d3dmetal, reason: "D3D12; global pin dxvk can't serve it", date }`. The global pin is unchanged. A decision line goes to the outcome log.
- Pass: the decision equals the expected JSON; the global pin file is byte-identical; option order matches; no download of D3DMetal is attempted.

**B. Steam updates the game while a repair runs, and a CLI starts a second repair.**
- The repair holds the prefix lock; (b3) sees `StateFlags` change and defers the post-update gate until the lock is free. The CLI repair gets exit 6 "Another repair is running on this bottle (pid N, started 12:01)".
- Pass: one committed transaction, no interleaved journal lines, the CLI exits 6 within 1 s.

**C. DB known-good at backend version X, X+1 installed and regressed.**
- The outcome log shows an `early-crash` for X+1 → row 9 → "DXMT 0.81 crashed this game; 0.80 is known to work. Use 0.80 for this game?" → install X side by side, per-game override `dxmt@0.80`.
- Pass: both versions present; other games keep X+1.

**D. D3DMetal 4.0b3 installed, you point at a 3.0 DMG.**
- Warning text as in §3.7. 4.0b3 is moved to `d3dmetal@4.0b3` before anything else.
- On approval: every Direct3D 12 game gets re-evaluated; the battery-cap note flips to "not available".
- Pass: backup present with an identical SHA-256; nothing replaced without approval; re-evaluation touched every D3D12 game.
- Integration test uses two fake framework folders with crafted Info.plist and feature strings. Apple's binaries are never copied into test fixtures.

## 6. Feature 4: crash test suite (extends `tests/stress/run.sh`)

**Isolation protocol** (all integration tests):
1. Test build: the app copied with bundle ID `local.cosmopolitan.test`, so it has its own settings.
2. Throwaway home via `CFFIXED_USER_HOME` (Phase 0 §12: `HOME` alone does not redirect `NSHomeDirectory()`).
3. Engine and backends are APFS clones.
4. One golden prefix booted once; each test gets an APFS clone of it, then its own wineserver, killed after the test.
5. **Tripwire** before and after every test: your bottle list, your log's timestamp, your Steam pid. Any change fails the run.
6. Orders: default, reverse, random with a printed seed. Results must match the isolated runs.

**Harness pieces:**
- **Fake Steam**: a mingw-built `steam.exe` placed at `C:\Program Files (x86)\Steam\` with crafted `appmanifest_*.acf`. It handles `-applaunch <id>` by starting the mapped test exe, and can flip `StateFlags` to simulate an update.
- **Test executables**: existing nine + `avx2probe.exe` (AVX2 ymm loop), `crash.exe` (null dereference, expect 0xC0000005), `hang.exe` (window that stops pumping messages), `nopresent.exe` (creates a D3D11 device, then stops presenting: device-lost and GPU-hang stand-in), `d3d8.exe`.
- **Unit tests**: Swift Testing in a SwiftPM test target for Swift code. A C++ test executable target (plain assert macros, no framework) for the core. `HostProfile` fixtures for M1–M6, A18 Pro, macOS 14/15/26/27/28, battery/AC, D3DMetal missing/3.0/4.x.

| # | Injection | Expected | Pass when |
|---|---|---|---|
| 1 | `kill -9` the test build between `swap` and `committed` (env `COSMO_TEST_CRASH_AT=swap`) | next start resumes the journal and swaps back | prefix boots (`cmd /c ver`), files equal pre-repair hashes |
| 2 | local HTTP server drops the connection / serves a wrong hash | nothing installed, cache entry kept, message names the component | target dir hash unchanged; exit 4 |
| 3 | truncate a backend DLL in the inventory | preflight reports a hash mismatch, repair restores it | DLL hash equals manifest |
| 4 | `crash.exe` | `early-crash`, combination marked failed, next candidate offered, ≤ 2 automatic retries | exactly 3 launches max; outcome lines present |
| 5 | `nopresent.exe` / `hang.exe` | watchdog after N s of no window updates and no CPU; `wineserver -k` for that prefix only; log bundle | your Steam pid unchanged; bundle file exists |
| 6 | mock `HostProfile` 8 GB + DB minimum 16 GB | warning shown; launch allowed | trace contains the memory warning |
| 7 | staging on a small RAM disk filled to 100 % | stage fails cleanly; nothing swapped | exit 4; journal ends `rolledback` |
| 8 | stale `.cosmo.lock` from a SIGKILLed holder; stale wineserver | lock acquired (flock was released); stale server detected per prefix | no deadlock within 2 s |
| 9 | mock: Rosetta not runnable | block with guidance | exit 2; text mentions `softwareupdate --install-rosetta` |
| 10 | rename the D3DMetal folder between preflight and launch | launch re-checks inventory at start, falls back or asks | no crash; message names D3DMetal |
| 11 | fake Steam flips `StateFlags` to updating during launch | launch waits or aborts with a message | no half-configured prefix (hash check) |
| 12 | manifest declares `min_macos` above the host | backend ineligible, next candidate | trace line present |
| 13 | malformed, truncated, oversized and random PEs into `cosmo-probe`; libFuzzer target (Homebrew LLVM; Apple clang 21 has no libFuzzer runtime, measured) for 120 s | "unreadable executable", never a crash | zero sanitizer reports; probe exit codes in range |
| 14 | per boundary function, a test hook that throws `std::bad_alloc` / `std::runtime_error` inside C++ | mapped to a Swift `Error` | process alive; error case matches |
| 15 | `cosmo-probe` gets `SIGSEGV` / sleeps forever (test env hook) | app survives, times out after 30 s, "probe failed", blocks or uses last-known-good | no guess in the decision; exit 5 |
| 16 | whole suite with `-sanitize=address,undefined` (Swift and C++), then `-sanitize=thread` | — | zero reports |
| 17 | regressions: (a) concurrent background checks during the licence hash; (b) DXVK 3 never chosen while MoltenVK lacks `shaderCullDistance`; (c) non-store programs get a correct light; (d) 64-bit DirectDraw never win98; (e) .NET never win98; plus Phase 0 N1 (bottle creation doesn't bake drivers), N2 (.NET runs in a new bottle), N3 (stale per-exe keys removed), N5 (Repair only touches its own prefix) | as fixed | each test fails on the old code and passes on the new |
| 18 | order: cnc-ddraw 32-bit → DirectDraw 64-bit, plus full random/reverse | identical results to isolated runs | result lines equal. `tests/stress/run.sh` now gives every test a fresh prefix clone (`ORDER=reverse|random`) |

**Issue C, root cause (confirmed 2026-10-23 with Steam session restarts):** in a fresh Steam session the 64-bit DirectDraw test passes alone. After one 32-bit cnc-ddraw run it fails, and the whole session reports an 800x600 screen (`GetSystemMetrics` and `EnumDisplaySettings` both). A cnc-ddraw run leaves the bottle's display mode at 800x600, and while Steam keeps the bottle's wineserver alive, every later program sees it. `ChangeDisplaySettingsEx(NULL)` can't restore it (`-2`), cnc-ddraw's `windowed=true` doesn't prevent it, and restarting Steam's session clears it. Without Steam the server exits between programs, which is why throwaway prefixes never showed it. Still open: which call sets the mode (needs Wine `+system` traces) and the fix (candidates: run cnc-ddraw games so the mode resets, or restart the bottle's session after a cnc-ddraw game exits).

## 7. Swift ↔ C++ boundary

**Today**: five `extern "C"` functions (Phase 0 §8). They are reentrant, not `noexcept`, and catch nothing; buffers are owned by Swift.

**Rules for every boundary function (new and migrated):**
- `extern "C" ... noexcept`, with a `try { … } catch (...) { return COSMO_E_INTERNAL; }` wrapper generated by one macro. Swift cannot catch C++ exceptions, and they terminate the program [V 69].
- Return a `cosmo_status` (0 = ok, typed codes) plus output through caller-owned buffers or a handle. Handles are opaque integers into a C++ registry of RAII objects, freed with `cosmo_release(handle)`. No raw owning pointers cross.
- The engine call is `cosmo_decision cosmo_decide(const cosmo_decision_input *in)`: plain C structs and enums in and out (D2), no shared state, no I/O.
- Thread safety documented per function. Rule: no mutable globals. Every function can be called from any Swift task concurrently.

**Helper process vs XPC for untrusted parsing:**

| | `cosmo-probe` subprocess (recommended first) | XPC service |
|---|---|---|
| crash isolation | yes | yes |
| usable from the CLI | yes, same binary | needs the app bundle's XPC registration |
| timeout and kill | `Process` + timer, `setrlimit` in the child | `invalidate()`; harder to hard-kill |
| plumbing | JSON on stdout | protocol + codable messages + Info.plist |
| cost per call | ~10–30 ms spawn [U, measure] | lower after warm-up |

**Thread-safety table (target):**

| Function | Thread-safe | From Swift concurrency |
|---|---|---|
| `cosmo_decide` | yes (pure) | yes |
| `cosmo_sha256_file` | yes | yes (blocking I/O: call from a detached task) |
| repair functions | yes, serialized by the prefix lock | yes, never on the main actor |
| `cosmo_controllers`, `cosmo_on_battery`, `cosmo_proc_find` | yes (no globals) | yes |

## 8. Order of work behind the flag

1. Test harness first: test build + throwaway home + golden prefix + tripwire + order modes. Regression tests for the five fixed bugs and N1–N3, N5.
2. `cosmo-probe` (PE, .NET header, AVX, hashing, Vulkan features) with fuzz + sanitizers. Fixes N7.
3. `HostProfile` + Inventory + capability manifests. Replace `driverUsable` with the capability rule.
4. Decision engine + CompatDB + gate UI/CLI + Windows-version invariants + owned per-exe keys.
5. Repair engine (lock, journal, swap, LKG, side by side) + D3DMetal version compare.
6. Learning + battery-cap honesty + chip defaults.
7. Scenarios A–D and tests 1–18 green under both sanitizer runs. Then the Phase 5 plan.

## 9. Decisions landed (remaining-work items, 2026-10-23)

Each item has its own commit and test (`tests/safety/<name>.sh`, all in `tests/run-all.sh`).

**22 GOG sign-in.** The sheet loads GOG's own login page in a private web view and catches the success address (https, `*.gog.com`, `on_login_success`, a `code`) in `decidePolicyFor`, before it loads; `didFinish` stays as a fallback and the paste step is gone. lgogdownloader `--browser-login` trades the code (60 s limit); the sheet shows "Signed in to GOG." or the reason in lgogdownloader's words. *Where the sign-in lives:* `~/.config/lgogdownloader/galaxy_tokens.json` (OAuth access and refresh token) and `cookies.txt`, mode 600; lgogdownloader honours `XDG_CONFIG_HOME` and has no Keychain support. *Keychain is feasible only by wrapping:* keep the token JSON in the login Keychain and, for each lgogdownloader call, write it to a private temporary `XDG_CONFIG_HOME` (mode 700), run the tool, store the refreshed tokens back (the refresh token rotates on use) and delete the folder. Costs: every call path goes through the wrapper, and a crash between run and write-back can lose a rotated token (sign in again). Not built; your call.

**24 Steam restarts.** A bottle's Steam is the `steam.exe` whose working folder is inside that bottle (Wine keeps the Unix working folder on the Windows current directory; Wine overwrites the environment block, so `WINEPREFIX` can't be read back); `cosmo_proc_find_in` in the native module. "Busy" = an app manifest in a download/update state, Steam's `Updating` flag, a `steamapps\common` process in that bottle, or Steam's `Running` flag. Setting-driven restarts (HUD, the Direct3D 12 driver change) wait and re-check every 20 s; Play and winetricks ask first. Stopping Steam never touches another bottle (it used to `pkill` every `steam.exe`).

**25 Battery text.** The Automatic summary says "D3DMetal 3.0 games: cap not available" when the installed D3DMetal lacks `D3DM_MAX_FPS`.

**26 Snapshots.** One `clonefile(2)` of the whole bottle (0.46 s for 28 000 files) before Repair, a driver switch, a registry sweep (only when it has work) and a Windows-version change (only when the version changes); never a full copy. Newest 3 per bottle, for 3 days (macOS Storage counts each clone at the bottle's full size, and game updates make it hold the old files), names matched exactly (`Steam` never prunes `Steam-2`'s); the daily cleanup follows the same rule (it used to keep two snapshots across all bottles). Disk use counts snapshot files the bottle has rewritten or deleted since, once across snapshots: an upper bound. Rollback stops only that bottle's wineserver and keeps the state before as a snapshot.

**39 Library.** Every bottle's games in one grid; the launch check works per game (`bottleOf(exe)`), so a game's status is right whatever bottle is selected, and Play selects the game's bottle first. Status words come from the launch check's light: green and yellow → Ready (Setting up… while first-start work runs), red with a fix → Needs a fix, red without → Won't run: reason (kernel anti-cheat, damaged file, missing files). Advanced is the previous window, behind Settings › Show advanced options. Outside Advanced no screen uses bottle, prefix, driver, DLL, registry, Wine, DirectX, Vulkan or msync (checked by a scan of the beginner screens' strings). One bottle per store, created automatically for stores added from the Library.

**40 Onboarding.** Silent checks first (chip, macOS, memory, free disk, Rosetta, Game Porting Toolkit, stores and games); This Mac only when limited (≤ 8 GB or < 30 GB free), Rosetta only when missing, Controller only when one is connected. Rosetta installs only after "Agree and Install", through macOS's administrator prompt. The toolkit is found on a mounted disk image and used only from the user's copy, with Apple's licence shown before accepting. The engine prepares in the background from the second screen; resume is by the saved screen; existing installs see "What's new" once. Store sign-ins chosen during onboarding open when the Library opens (a sheet can't present another sheet). Test builds get their own preferences domain per throwaway home (macOS keeps preferences per user, not per HOME).

**27 Driver fallback.** Decision-table row 12 (`cosmo_fallback`, C++, with table tests): after a crash within 30 s, the next of DXMT → D3DMetal → DXVK that serves the game's main API and hasn't failed here; the user's own DRIVERS pin is asked about, never switched; none left → back to automatic. One retry per session. The working driver is written to the game's Options under a `# driver fallback:` line (with the drivers that crashed and the date) and appears in the prefilled compat report. Crash triage no longer rolls a recently updated driver back on its own: it asks.

**28 Pre-flight.** `cosmo_preflight` (C++): Direct3D/DirectDraw imports → API bits; a .NET (CLR) header or `mscoree.dll` → Wine Mono; a Visual C++ 2015–2022 DLL → that runtime in the program's bitness; a DirectX June 2010 DLL → DirectX. Visual C++ comes from Microsoft's pinned installer unless the game ships the DLL or the bottle's copy is already Microsoft's (every bottle has Wine's stand-in, which doesn't count); DirectX only when its DLL is really missing (Wine's own d3dx9 serves the rest). The PE reader reports the CLR header (data directory 14). The DLLs beside a program add their imports to the graphics APIs and runtimes, never to "missing DLLs" (an unused plugin may import anything); games that load Direct3D at runtime are still found by the existing scan of large engine modules for D3D names.

**29 Anti-cheat.** `cosmo_anticheat` (C++), first match wins: kernel anti-cheat → block; AreWeAntiCheatYet Denied or Broken → block; EAC/BattlEye files, or Supported/Running/Planned → warn (on a Mac, Wine has no anti-cheat runtime even where Proton does, so online play is expected to fail); nothing known → fine. AreWeAntiCheatYet's `games.json` (MIT) is fetched at runtime into the cache, at most daily, and never bundled; looked up by Steam app id, else by name.

**30 Save backups.** The Ludusavi manifest (MIT) is fetched at runtime into the cache, at most weekly, and read with a line reader for its fixed shape (no YAML library). A game's Windows save paths are resolved inside its bottle (`<winAppData>`, `<base>`, `<home>`, `<storeUserId>` → `*`, …; Linux/Mac-only and other-store rules skipped; `**` read as one level) and cloned into `support/save-backups/<game>/<stamp> <reason>/`, newest 5 kept. Taken before Repair (the whole bottle), before a driver switch (Bisect, fallback, the Direct3D 12 change) and once per pending Steam update (an app manifest with an update state, checked every minute).

**31 Template bottles.** The first bottle made with an engine version and Windows version becomes `support/templates/<engine> <wine --version> <winver>` once it is complete (Wine Mono in, and its wineserver gone, so the registry is on disk); later bottles are one `clonefile` of it. A new engine version has no template, so its first bottle is built normally and replaces the older template. `--newbottle` now returns when the bottle is ready instead of after a fixed 90 s.

**32 Battery profile.** The 60 fps cap and lighter DXMT rendering apply on battery, in Low Power Mode (`isLowPowerModeEnabled`) and under serious thermal pressure; `--status` names the reason.

**33 Controller on connect.** A `GCControllerDidConnect` sets the bottle's controller bus for SDL pads (DisableHidraw 1, SDL on) when it isn't, checked live with `reg query` (system.reg lags while Wine runs); left alone while a game in DualSense native mode runs.

**34 Crash capture.** Every program that exits with an error leaves `support/crash-reports/<game> <stamp>.txt`: the last 80 log lines, the drivers it ran with, and the app, engine, D3DMetal, driver and macOS versions; newest 20 kept. The bug report attaches the newest (for the game it is about), with the username and home folder removed.

**35 Health check.** At start: template-sourced drivers against their pinned tree hashes (a driver updated through Update… keeps `<name>.old` and is the user's), Wine Mono in every bottle, no ledger settings of programs that are gone, at least 10 GB free. Problems show in the Library with Fix; Fix this game fixes its bottle's first. Putting a driver back asks first and keeps the current copy as `.old`.

**36 Cleanup suggestions.** Shader caches of games no longer installed, leftover installers, Windows and user temp files, biggest first, in Settings; only the chosen items go, after a confirmation (the CLI needs `--yes`). A bottle's temp folders are kept while a program runs in it (an installer may still need them).

**37 Launchers.** A launcher app per Library game in `~/Applications/Cosmopolitan Apps` (Dock, Launchpad, Spotlight) that opens `cosmopolitan://launch?name=…` with the Cosmopolitan that made it, so every start goes through the launch checks; launchers of games that are gone are removed (only ours, marked in their Info.plist). App Intents: "Play a game" with the Library's games as entities, App Shortcuts phrases "Play <game> in Cosmopolitan"; `scripts/build.sh` extracts `Metadata.appintents` with Xcode's `appintentsmetadataprocessor` (whole-module build, constant values). Test builds strip that metadata so their intents never reach Shortcuts.

**38 Nightly self-test.** `tests/nightly.sh` runs `tests/run-all.sh` (throwaway homes, isolation guard, sandbox, tripwire) and reports only failures: a notification and the log in `~/Library/Logs/Cosmopolitan self-test/`. `scripts/install-nightly.sh` installs the LaunchAgent `local.cosmopolitan.selftest` (04:00, low priority); `--uninstall` removes it.

**REDprelauncher games (The Witcher 3, Cyberpunk 2077).** The tile's program is CD Projekt's prelauncher; `launcher-configuration.json` names the real game, which the launch check inspects with its own folder's DLLs (The Witcher 3's DirectX 12 build loads Direct3D 12 through NVIDIA Streamline, so only the DLLs beside it show it: D3DMetal). Play adds `--launcher-skip` (and `-dx12`/`-dx11` for the configured build): REDlauncher's Qt Quick window can't get an OpenGL context under this Wine although plain OpenGL 2.1 works, and the prelauncher clears Qt's environment variables, so the launcher can't be helped from outside; it isn't needed to play. Sikarugir's Wine carries a built-in rewrite of `…\bin\x64_dx12\witcher3.exe` to `…\bin\x64\witcher3.exe` (the DirectX 11 build, gone from the current DirectX 12-only game): when the engine has that rule and `bin\x64` doesn't exist, Play links `bin\x64` → `x64_dx12` after a snapshot (delete the link to undo).

## Sources

**Apple Read Me files** (primary sources on this Mac, quoted verbatim above):
- R3. "Evaluation environment for Windows games 3.0 README", `Read Me.rtf` in your GPTK 3.0 disk image.
- R4. "Evaluation environment for Windows games 4.0 beta 2 README", `Read Me.rtf` beside the D3DMetal 4.0b3 framework in `~/Cosmopolitan-testrun-2032/d3dmetal-old`. That copy came from Sikarugir's template; only Apple's text is cited, the binaries are not reused.

**Backends and Steam** (B):
- B1 https://support.codeweavers.com/miscellanous/advanced-settings-in-crossover-mac
- B3 https://github.com/3Shain/dxmt · B3b https://github.com/3Shain/dxmt/releases
- B4 https://github.com/doitsujin/dxvk
- B5 https://github.com/Gcenx/DXVK-macOS/releases/tag/v1.10.3-20230507 · B5b …/tag/v1.10.3-20230507-repack ("Removed d3d9.dll & dxgi.dll") · B5c https://github.com/Gcenx/DXVK-macOS
- B6 https://github.com/HansKristian-Work/vkd3d-proton
- B7 https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/d3d12/d3d12_main.c
- B8 https://github.com/FunkyFr3sh/cnc-ddraw
- B9 https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/ddraw/Makefile.in (and d3d8, d3d9, d3d10core, d3d11) · B9b https://raw.githubusercontent.com/wine-mirror/wine/wine-10.0/ANNOUNCE.md
- B10 https://developer.apple.com/documentation/macos-release-notes/macos-mojave-10_14-release-notes ("The APIs in the OpenGL and OpenCL frameworks are deprecated")
- B11 https://support.apple.com/en-us/101525
- B12 https://github.com/doitsujin/dxvk/commit/5a4d89217249780e17451dbf6c7f678a4a0d472d
- B13 https://github.com/doitsujin/dxvk/releases/tag/v2.7
- B16 https://raw.githubusercontent.com/doitsujin/dxvk/master/src/dxvk/dxvk_device_info.cpp · B16b …/v3.1.1/src/dxvk/dxvk_device_info.cpp
- B19 https://raw.githubusercontent.com/KhronosGroup/MoltenVK/main/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm ("maxCullDistances = 0; // unsupported")
- B23 https://raw.githubusercontent.com/HansKristian-Work/vkd3d-proton/master/libs/vkd3d/device.c
- B24 https://raw.githubusercontent.com/KhronosGroup/MoltenVK/main/Docs/MoltenVK_Runtime_UserGuide.md
- B27 https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance
- B28 https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled
- B29 https://support.apple.com/en-us/102297 · B30 https://support.apple.com/en-us/105118 · B31 https://support.apple.com/en-us/101613
- B32 https://store.steampowered.com/news/191068/ · B34 https://raw.githubusercontent.com/SteamRE/open-steamworks/master/Open%20Steamworks/AppsCommon.h
- B35 https://github.com/Gcenx/macOS_Wine_builds · B36 https://raw.githubusercontent.com/wine-mirror/wine/master/LICENSE · B37 https://raw.githubusercontent.com/KhronosGroup/MoltenVK/main/LICENSE · B38 https://raw.githubusercontent.com/3Shain/dxmt/main/LICENSE
- B39 https://gstreamer.freedesktop.org/download/ · B40 https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html · B41 https://raw.githubusercontent.com/libsdl-org/SDL/main/LICENSE.txt · B42 https://github.com/madewokherd/wine-mono
- B43 https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist · B44 https://www.microsoft.com/en-us/download/details.aspx?id=8109 · B45 https://dotnet.microsoft.com/en-us/download/dotnet-framework/thank-you/net48-offline-installer

**Hardware and OS** (numbers):
1. Metal feature set tables (May 2026) — https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
3. M1 MacBook Air tech specs — https://support.apple.com/en-us/111883
9. M2 MacBook Air tech specs — https://support.apple.com/en-us/111867
14. Apple newsroom, M3 family — https://www.apple.com/newsroom/2023/10/apple-unveils-m3-m3-pro-and-m3-max-the-most-advanced-chips-for-a-personal-computer/
15. M3 MacBook Air tech specs — https://support.apple.com/en-us/118551
17. Apple newsroom, M3 Ultra — https://www.apple.com/newsroom/2025/03/apple-reveals-m3-ultra-taking-apple-silicon-to-a-new-extreme/
19. Apple newsroom, M4 — https://www.apple.com/newsroom/2024/05/apple-introduces-m4-chip/
20. Apple newsroom, iPad Air M4 — https://www.apple.com/newsroom/2026/03/apple-introduces-the-new-ipad-air-powered-by-m4/
21. M4 tech specs — https://support.apple.com/en-us/122209
22. Apple newsroom, M4 Pro/Max — https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/
24. Apple newsroom, M5 — https://www.apple.com/newsroom/2025/10/apple-unleashes-m5-the-next-big-leap-in-ai-performance-for-apple-silicon/
25. M5 tech specs — https://support.apple.com/en-us/126320
26. Apple newsroom, M5 Pro/Max — https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/
27. M5 Pro/Max tech specs — https://support.apple.com/en-us/126318
28. Apple newsroom, M6 and M5 Ultra — https://www.apple.com/newsroom/2026/08/apple-introduces-m6-and-m5-ultra-for-a-big-leap-in-performance-and-ai-compute/
29. M5 Ultra tech specs — https://support.apple.com/en-us/128107
30. Apple newsroom, Mac Studio M5 Max/Ultra — https://www.apple.com/newsroom/2026/08/apple-introduces-new-mac-studio-with-m5-max-and-m5-ultra/
31. M6 tech specs — https://support.apple.com/en-us/128108
32. MacBook Neo tech specs — https://support.apple.com/en-us/126322
33. Apple newsroom, MacBook Neo — https://www.apple.com/newsroom/2026/03/say-hello-to-macbook-neo/
34. MTLGPUFamily — https://developer.apple.com/documentation/metal/mtlgpufamily
35. supportsRaytracing — https://developer.apple.com/documentation/metal/mtldevice/supportsraytracing
36. recommendedMaxWorkingSetSize — https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize
37. WWDC23 10128 (ray tracing) — https://developer.apple.com/videos/play/wwdc2023/10128/
38. Tech talk 111375 (Apple family 9 GPU) — https://developer.apple.com/videos/play/tech-talks/111375/
39. About the Rosetta translation environment — https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment
43. Apple Support, Rosetta — https://support.apple.com/en-us/102527
45. macOS 27 release notes — https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
46. Apple Developer Forums, staff reply on Rosetta and games — https://developer.apple.com/forums/thread/830692
50. WWDC25 209 ("Game Porting Toolkit 3 also adds support for Metal 4") — https://developer.apple.com/videos/play/wwdc2025/209/
51. Apple Game Porting Toolkit page ("Download Game Porting Toolkit 4") — https://developer.apple.com/games/game-porting-toolkit/
56–61. Apple newsroom posts stating fanless MacBook Air M1–M5 (URLs in the research notes)
69. swift.org C++ interop status ("terminates with a fatal error when a C++ exception … reaches Swift code") — https://www.swift.org/documentation/cxx-interop/status/
70. Microsoft, .NET Framework system requirements (Windows 7 SP1 oldest client for 4.6.2–4.8.x) — https://learn.microsoft.com/en-us/dotnet/framework/get-started/system-requirements
71. `man 2 rename` on macOS 27 (RENAME_SWAP: "cause the source and target to be atomically swapped", subject to `VOL_CAP_INT_RENAME_SWAP`)
72. `man 2 flock` on macOS 27 ("Locks are on files, not file descriptors … duplicated through dup(2) or fork(2) … multiple references to a single lock")
