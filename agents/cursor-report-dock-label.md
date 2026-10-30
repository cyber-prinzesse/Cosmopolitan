# Cursor report: Dock labels by loader file name

**Worktree:** `~/Cosmopolitan-cursor`  
**Branch:** `dock-label-by-loader` (from `origin/main` @ `d418e12` / 1.3.22) — **not pushed**  
**Never touched `~/Cosmopolitan` or real bottles/engines** (read-only).

---

## Finding (verified before the fix)

macOS names a Wine app in the **Dock** after the **executable file name** it was `exec`'d as (`bin/wine` → `"wine"`, `bin/Steam` → `"Steam"`).

1.3.21/1.3.22 set LaunchServices display name via `cosmo_nodock` (`_LSSetApplicationInformationItem` / `CFBundleName`). `lsappinfo` showed `"REDlauncher"` / `"Solo Name — Test"`, but the Dock ignored it.

**False pass:** `steam_dock_addon.sh` only checked `lsappinfo`.

**Probe on main-style launch (raw `bin/wine` + dock-names.txt):** Dock list contained `wine`, not `Solo Name — Test`.  
**Probe with a named wine copy:** Dock showed `Solo Name — Test`.

## Fix

Tiny **dispatcher** `cosmo_wineloader` (x86_64, `EngineAddon/`):

1. Cosmo installs it into `bin/cosmo_wineloader` (and on Wine 11 replaces `lib/wine/x86_64-unix/wine`, real loader → `wine.cosmo-real`).
2. `loaderNamed` returns the dispatcher; `WINELOADER` stays on it; `COSMO_LOADER_NAME` is the host fallback (`Steam`, …).
3. On each exec, argv[1] (Windows exe path) is looked up in `$WINEPREFIX/options/dock-names.txt` or Mac Driver `AppName`, then `execv` of a real wine copy named `<dir>/<Name>` (spaces → U+00A0).
4. No entry → `$COSMO_LOADER_NAME` / `wine`. CLI still logs `$ Steam …` (host name, not the dispatcher file).

Stale-copy prune never removes `cosmo_wineloader`, `wine.cosmo-real`, or an in-use named copy.

## Test changes

- `steam_dock_addon.sh`: assert Dock labels via  
  `osascript … name of every UI element of list 1 of process "Dock"`  
  (normalize NBSP → space). Confirmed this check fails when the loader file is still `wine`.
- `dock_names.sh`: Steam child through dispatcher gets its own Dock label; host stays Steam; Wine 11 unix/wine is the dispatcher; in-use prune kept.

## Tests

```
PASS steam_dock_addon
PASS dock_names          # Wine 10 + Wine 11 (highball-11.0-r29)
PASS steam_restart
PASS steam_launch_options
PASS launchers
PASS scan_no_dupes
```

## Files

- `EngineAddon/cosmo_wineloader.c` — dispatcher
- `Sources/Model/Launch.swift` — install / `loaderNamed` / prune
- `Sources/Model/Process.swift` — `WINELOADER` + `$ Steam` log
- `Sources/App/App.swift` — `--loader-name` shows dispatcher path
- `scripts/build.sh` — ship `cosmo_wineloader`
- `tests/safety/steam_dock_addon.sh`, `dock_names.sh`
- `agents/cursor-report-dock-label.md`

Co-Authored-By: Cursor <noreply@cursor.com>
