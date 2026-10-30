# Cursor report: REDlauncher Dock name

**Worktree:** `~/Cosmopolitan-cursor`  
**Branch:** `redlauncher-dock-name` (from `origin/main` @ `fdd5024` / PR #32 / 1.3.21) — **not pushed**  
**Never touched `~/Cosmopolitan` or the real bottles** (read-only on everyday `bottles/Steam`).

---

## Symptom

Starting The Witcher 3 from Steam shows the REDlauncher window (CDPR bird) with Dock name **"Steam"**.  
`cosmo_nodock.dylib` (1.3.21) is loaded; real `options/dock-names.txt` listed `magicka2.exe`, `redprelauncher.exe`, `witcher3.exe` — not `redlauncher.exe`.

## Cause

`writeDockNames` only maps executables under the Steam game folder (tile + `Model.redGame` / Unreal shipping).  
`REDlauncher.exe` lives under `drive_c/users/…/AppData/Local/Programs/CD Projekt Red/REDlauncher/`, outside `steamapps/common`, so it never entered the list.

## Fix

For each Steam program where `Model.redGame(dir)` succeeds, also write:

```
redlauncher.exe	REDlauncher
```

Fixed shared name — never a game title (one launcher for Witcher, Cyberpunk, …). Multiple CDPR games still yield a single Set entry `"REDlauncher"`.

## Clone check (APFS `cp -cR`, throwaway testenv)

| Bottle | `dock-names.txt` |
|--------|------------------|
| Real Steam (read-only) | magicka2, redprelauncher, witcher3 — **no** redlauncher |
| Clone after `ct --status` | same **+** `redlauncher.exe → REDlauncher` |

Real bottle file unchanged after the check.

## Tests

```
PASS steam_dock_addon   # FakeW + CDPR launcher-configuration.json → redlauncher + witcher3 + redprelauncher
PASS dock_names
PASS scan_no_dupes
PASS launchers
```

## Files

- `Sources/Features/NoDockAddon.swift` — `writeDockNames` CDPR shared `redlauncher.exe`
- `tests/safety/steam_dock_addon.sh` — stand-in Witcher layout asserts
- `agents/cursor-report-redlauncher-name.md` — this report

Co-Authored-By: Cursor <noreply@cursor.com>
