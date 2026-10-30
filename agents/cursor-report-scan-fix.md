# Cursor report: scan-no-dupes real-bottle fix

**Worktree:** `~/Cosmopolitan-cursor`  
**Branch:** `scan-no-dupes` (not pushed)  
**Never touched `~/Cosmopolitan`.**

---

## Regressions fixed (verified on APFS clone of everyday `bottles/Steam`)

| # | Symptom | Fix |
|---|---------|-----|
| 1 | Witcher tile vanished | `isHelperExe` never treats `steamGames` / `epicGames` paths as helpers. Steam walk digs to depth 4 when every shallow hit is a helper candidate, and prefers a non-helper (e.g. `witcher3.exe` over `REDprelauncher.exe`). |
| 2 | `--find` added BlizzardError / GameSessionMonitor / FMSIScan; Battle.net showed as two tiles | `isReporterOrMonitorExe`; Find apps skips `bdk` / `systeminfo` / `Battle.net.NNNNN`; `libraryIdentity` collapses Battle.net Launcher + `Battle.net.exe` to `battlenet:<root>`. |
| 3 | `.cosmo-score-*` beside exes outside a bottle | Score cache under `bottles/<B>/options/.score-<leaf>` or `support/cache/score-…` — never next to the exe. |

## Clone check (temporary tile print, not committed)

Same-day `cp -cR` of `~/Library/Application Support/Cosmopolitan/bottles/Steam` into a `testenv` home; `cosmopolitan.apps` paths rewritten into the clone so absolute real-bottle entries do not invent a second identity.

| Build | Tiles |
|-------|-------|
| `main` @ 131c114 | **6:** Battle.net Launcher, Battle.net.exe (duplicate), Epic Games, Magicka 2, Steam, Witcher (REDprelauncher) |
| `scan-no-dupes` (this fix) | **5:** Battle.net ×1, Epic Games, Magicka 2, Steam, Witcher (`steam:292030`) |

Branch = main’s list minus the Battle.net duplicate; Witcher kept. No helpers (BlizzardError / GameSessionMonitor / FMSIScan) as tiles.

## Tests

```
PASS scan_no_dupes
# Layouts: Witcher REDprelauncher + launcher-configuration.json + witcher3;
#          Battle.net Launcher + Battle.net.exe + Battle.net.17952/bdk/BlizzardError;
#          Futuremark/SystemInfo/FMSIScan.exe
# Expect: Witcher×1, Battle.net×1, no helpers, second --find adds 0, no .cosmo-score-* beside external folder
```

## Files

- `Sources/Core/Programs.swift` — store never helpers; reporters; battlenet identity; score → support/options
- `Sources/Core/Drivers.swift` — skipExes extras
- `Sources/Model/Model.swift` — Steam depth-4 + prefer non-helper
- `Sources/Features/FindApps.swift` — skip bdk/systeminfo/Battle.net.NNNNN; filter helpers
- `tests/safety/scan_no_dupes.sh` — regression layouts above
