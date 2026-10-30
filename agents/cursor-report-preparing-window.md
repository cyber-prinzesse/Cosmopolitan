# Preparing window (Cosmos chrome) — report

**Branch:** `preparing-window` (from `origin/main`)  
**Status:** done locally; not pushed / not released

## What

Native stand-in for Wine’s “please wait…” (off on Cosmos; still under us on Wine 10): glass + white outline with a travelling thick **snake** (~1.6 s / lap). Squircle only — `clipShape` + clear `NSHostingView` so the sharp black corners are gone.

## Lifecycle checks (before calling done)

- **No flash under ~0.5 s:** `begin` schedules `present` with `asyncAfter(0.5)`; `end` cancels `showWork` before the panel can appear.
- **Closes on fail / cancel, not only success:** `createBottle` calls `PreparingWindow.end()` in the wineboot `then` (Wine’s `terminationHandler` always invokes `then`, including non-zero exit). `wine()` / `exec()` also invoke `then` when the engine is missing or `Process.run` throws, so the window cannot stick open. `DriverCopies` uses `defer { end() }` around a blocking wineboot. `Setup` ends after its sync shell regardless of bottle creation success.
- **Never in `cliMode`:** `begin` is a no-op unless `force` (`--preview-preparing`) or `!cliMode`.

## Files

- `Sources/UI/PreparingWindow.swift` — panel + chrome + snake + corner cut
- `Sources/Model/Process.swift` — `then` on engine-missing / launch failure (so `end` always runs)
- Hooks: `Bottles.swift` (create), `DriverCopies.swift` (stale prefix), `Setup.swift` (first bottle)
- `Sources/App/App.swift` — `--preview-preparing [seconds]`
- `Resources/cosmos-glass-1024.png`
- `scripts/build.sh` — packs the PNG

## Screenshots (window-only, final look)

`agents/preparing-window-shots/`

- `preview-now.png` — corner-cut squircle (final chrome)
- `snake-2.png` … `snake-5.png` — snake phases
- `reduce-motion.png` — `COSMO_TEST_REDUCE_MOTION=1` pulse path

## Tests

- `tests/safety/dotnet_new_bottle.sh`
- `tests/safety/templates.sh`
