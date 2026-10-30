# ADR-0001: Cosmos — Cosmopolitan builds its own Wine engine, and Dock fixes live in it

**Status:** Accepted (building the engine). Making it the default stays gated, see Action Items.
**Date:** 2026-10-30
**Deciders:** cyber-prinzesse (owner)

## Context

Cosmopolitan runs Windows programs on two engines it does not build:

- **Wine 10, `WS12WineSikarugir10.0_8`**, the default. Sikarugir's prebuilt engine. Its Mac driver exports a
  `macdrv_functions` table that D3DMetal and DXMT call and that public Wine lacks, so it cannot be rebuilt without
  breaking them. Decision of 2026-10-23 (`Sources/Core/Components.swift`): kept until an upstream engine passes the
  test suite.
- **Wine 11, `highball-11.0-r29`**, the Beta's default. Highball's build of Wine 11 for macOS plus
  Highball's patch series (gauthierpiarrette/highball-engine).

Because neither engine is ours, every engine-level fix has shipped as an app-side workaround:

| Problem | Workaround today | Where |
|---|---|---|
| Steam has two Dock icons | `cosmo_nodock.dylib`, added to each engine's `winemac.so` as an extra `LC_LOAD_DYLIB`; swizzles `transformProcessToForeground:` | `EngineAddon/cosmo_nodock.m` |
| Every program shows as "wine" / "Steam" in the Dock | `cosmo_wineloader`: replaces `lib/wine/x86_64-unix/wine` on Wine 11 (real one kept as `wine.cosmo-real`), copies the loader to `bin/<Name>` per name, passes `argv[0]` = itself so children come back | `EngineAddon/cosmo_wineloader.c`, `Launch.swift` |
| D3D12 games hang forever on a fault in a Metal thread | patched `ntdll.so` copied by hand into the user's Beta engine | not shipped |

These work, but they modify engine files at runtime, depend on undocumented behaviour (REA showed ntdll rewrites
`WINELOADER` from `basename(argv[0])`; the Dock label is the exec'd file name), race when Steam starts helpers at
once (fixed with temp-file renames), and reach only users whose engine has been patched in place. Engine updates
undo them until the app reapplies them.

REA on the shipped r29 `ntdll.so` (sha256 `37b813de…`, Evidence `ev_db7713c7…`) showed the engine already has the right
mechanism for Dock names (hack 22144: exec a hard link named after the exe), but it only runs when plain
`WINEDLLPATH` is set. Cosmopolitan never sets it (it broke DXMT, `LaunchEnvironment.swift:53`), so it never ran.

Constraints:
- Wine is LGPL-2.1-or-later: a distributed build must come with its complete corresponding source.
- macOS x86_64 under Rosetta (the Unix side of this Wine tree is x86_64-only).
- No paid build infrastructure; one maintainer plus agents.
- Users' bottles must not break; a Wine 11 upgrade of a bottle cannot be undone (snapshot first).

## Decision

Build Cosmopolitan's own Wine 11 engine, **Cosmos**, from `cyber-prinzesse/cosmos-engine`: Highball's recipe and patch
series (merged from upstream `main`) plus Cosmopolitan's patches, built by GitHub Actions (`build.yml` with
`cosmos_revision`), published as `cosmos-<wine version>-r<N>.tar.gz` with `COSMOS-BUILD.txt` (source pin, patch list,
commit). Engine-level fixes become patches in that series instead of app-side add-ons:

- `0028` ntdll: a fault on a thread Wine didn't create ends the program (D3D12 hang).
- `0029` ntdll: Dock name from the Mac Driver `AppName` (read by the parent in `spawn_process`, passed as
  `WINEMACAPPNAME`) or the exe name; hack 22144 also runs when the loader sits beside `ntdll.so`.
- `0030` winemac: Mac Driver `NoDockIcon` makes a program an accessory app.

Cosmos is described as "based on Wine". Wine 10 (Sikarugir) keeps the app-side add-ons until Cosmos replaces it.

## Options Considered

### Option A: Keep third-party engines, fix things app-side (status quo)

| Dimension | Assessment |
|---|---|
| Complexity | Medium, growing: every fix is a binary-level workaround |
| Cost | None for builds |
| Robustness | Low: runtime file surgery, races, undone by engine updates |
| Team familiarity | High (already shipped in 1.3.19–1.3.24) |

**Pros:** no build pipeline; works on Wine 10 too; no LGPL distribution duty for the engine.
**Cons:** can't fix anything the app can't reach from outside (the D3D12 hang); depends on reverse-engineered
behaviour that may change in any engine release; each fix needs a live check per engine.

### Option B: Own build on Highball's recipe — Cosmos (chosen)

| Dimension | Assessment |
|---|---|
| Complexity | Medium: a patch series plus merging upstream |
| Cost | Free (public repo, hosted macOS runners); a few hours per build |
| Robustness | High: fixes are in source, reviewed, reproducible |
| Team familiarity | Medium: Wine source is new ground, but the recipe and CI already exist |

**Pros:** real fixes at the right layer; one engine for everyone, not hand-patched copies; reproducible, pinned
builds; Highball's 27 patches and the tree's macOS work come along; our patches can be offered upstream.
**Cons:** we own merges with Highball and new Wine source releases; we owe an LGPL source offer; CI builds are slow; a bad
patch breaks every program, not one feature.

### Option C: Own build from plain WineHQ Wine 11

| Dimension | Assessment |
|---|---|
| Complexity | High |
| Cost | Free CI, much more engineering time |
| Robustness | Unknown on macOS |
| Team familiarity | Low |

**Pros:** cleanest licensing story; no dependency on vendor source drops.
**Cons:** loses the macOS work in the tree we build from (msync, D3DMetal/DXMT hooks in the Mac driver, the Rockstar
installer fix); upstream WineHQ has no current macOS-capable equivalent. Not viable now.

### Option D: Upstream our patches to Highball and keep using their builds

| Dimension | Assessment |
|---|---|
| Complexity | Low for us |
| Cost | None |
| Robustness | High once merged |
| Team familiarity | High (PR #24 already open) |

**Pros:** no pipeline to own.
**Cons:** our fixes ship on Highball's schedule and only if accepted; Cosmopolitan-specific choices (how names are
given) may not fit Highball. Still worth doing alongside B.

## Trade-off Analysis

The real choice is between A and B. A costs nothing up front but every new engine problem becomes an
investigation into undocumented binaries, and some problems (the D3D12 hang) can't be fixed from outside at all.
B front-loads a pipeline (already working: Highball's CI, forked) and a maintenance duty (merging upstream), and in
return every fix is a reviewable source change shipped identically to every user. C is the purist version of B
without the macOS work that makes Wine usable there. D complements B: offering patches upstream keeps our series
small, and B means we never wait on it.

## Consequences

- **Easier:** fixing engine bugs (patch, build, test); explaining the engine (`COSMOS-BUILD.txt`, `patches/README.md`);
  dropping `cosmo_wineloader` and `cosmo_nodock` once Wine 10 is gone; Dock names that need no file copies.
- **Harder:** keeping up with Highball and new Wine source releases (merge, rebuild, retest); every Cosmos release carries an LGPL
  source obligation (the pinned Wine source tarball, hosted on our own releases, + `patches/` at the release commit);
  CI build time (hours) slows iteration.
- **The app changes:** on Cosmos it must skip installing the loader stand-in and the Mac-driver add-on, write names as
  registry `AppName` (also for Steam games, instead of `options/dock-names.txt`), set `WINEMACAPPNAME` for the first
  program, and set `AppName=Steam` for `steamwebhelper.exe`.
- **Revisit:** drop `0028`–`0030` when Highball or upstream ship equivalents; Highball's arm64 line (Wine 11.18 + FEX)
  for the end of Rosetta; whether Wine 10 can go once Cosmos is the default.

## Action Items

1. [x] Create `cyber-prinzesse/cosmos-engine`, add `cosmos_revision` to `build.yml`, `COSMOS.md`, icon, "based on Wine".
2. [x] Patches `0029` (Dock names) and `0030` (NoDockIcon); compiled against the configured tree.
3. [x] GitHub builds green (r1 75 min; with the compile cache about 25 min). r6 has 0028–0031, theme and icon.
4. [x] `tests/safety/dock_label_child.sh` passes on r6 with the app change in PR #37. Testing found the loader's hard links
   gave every program one shared name; 0029 now uses APFS clones.
4a. [x] Local build on this Mac (`~/Cosmopolitan-engine-trials/cosmos-build/build.sh`): full build 9 min, a change in
   about 1–2 min.
4b. [x] The engine bundles its host libraries (`cosmos-tools/bundle-hostlibs.py`, 22 libraries, 15 MB); before, it had
   no fonts unless the app copied Sikarugir's in.
4c. [x] Look: black theme for Wine's own windows, dark title bars, the Cosmos icon on every program (owner's choice;
   `ProgramIcon=y` keeps a program's own).
5. [~] App: detect Cosmos (`COSMOS-BUILD.txt`), skip add-ons there, write `AppName`, set `WINEMACAPPNAME`: PR #37 (draft).
6. [ ] Full test suite with `COSMO_ENGINE` = Cosmos; fix what fails.
7. [ ] Publish the first Cosmos release with its source offer; pin its SHA-256 in `Components.swift`.
8. [ ] Make Cosmos the Beta's engine; single live checks on the owner's setup (Steam, REDlauncher/Witcher 3, Battle.net, controller).
9. [ ] Make Cosmos the default (1.4), with snapshot-before-upgrade and Wine 10 kept as fallback for a few releases.
10. [ ] Offer `0029`/`0030` to Highball alongside PR #24.
