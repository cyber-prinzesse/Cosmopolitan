# Preparing window (Cosmos chrome) — report

**Branch:** `preparing-window` (from `origin/main`)  
**Status:** implemented locally; not pushed / not released

## What

Replaces Wine’s “please wait…” (already off on Cosmos; still under us on Wine 10) with a native black panel: glass only, thin rounded-square track (`Cosmo.rule`), thick off-white **snake** trimmed along an inset path (~1.6 s / lap). Shows after 0.5 s; never in `cliMode` except `--preview-preparing`.

## Files

- `Sources/UI/PreparingWindow.swift` — panel + chrome + snake
- Hooks: `Bottles.swift` (create), `DriverCopies.swift` (stale prefix), `Setup.swift` (first bottle)
- `Sources/App/App.swift` — `--preview-preparing [seconds]`
- `Resources/cosmos-glass-1024.png` (copied from engine-trials assets)
- `scripts/build.sh` — packs the PNG

## Screenshots (window-only)

`agents/preparing-window-shots/`

- `snake-2.png` … `snake-5.png` — fat segment on the outline at different phases (matches sketch)
- `reduce-motion.png` — `COSMO_TEST_REDUCE_MOTION=1` pulse path (full outline, no snake)

## DualSense

Unrelated branch `dualsense-stick-buzz` (stashed WIP). XInput A/B test **not** run yet — waiting for your **yes** to comment out `DUALSENSE=native` in the real Steam bottle.

## Tests

- `tests/safety/dotnet_new_bottle.sh` — **PASS**
- `tests/safety/templates.sh` — **PASS**
- `--preview-preparing` — window 220×220, layer 3; snake frames on-path
