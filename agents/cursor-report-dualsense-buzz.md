# DualSense stick-turn buzz — report

**Branch:** `dualsense-stick-buzz` (fast-forwarded to `origin/main`)  
**Status:** done locally; not pushed  
**Owner:** pad works perfectly now.

## Which change fixed it, and why

Two app-side fixes landed together:

1. **Winebus stamp + Steam reload** (`touchWinebusStamp` / `winebusNeedsSteamReload` in `DualSense.swift`, wired in `Launch.swift`).  
   Wine reads `DisableHidraw` only when the prefix’s wineserver starts. Flipping native ⇄ XInput (or pad-connect) under a live Steam left the old bus in memory, so the pad could buzz or mis-handle sticks until a blind restart. The stamp marks every winebus write; if Steam is up and its wineserver is older than the stamp, launch sets `need.restartSteam` so Cosmo restarts Steam before the game.

2. **Steam cwd detect** (`steamRunning()` in `Model.swift`).  
   After the Dock loader/`cosmo_wineloader` path, `steam.exe` often has cwd under `$HOME`, so “cwd inside the bottle” missed it. Restart-Steam never armed. Detection now: bottle wineserver present **and** any process whose argv still shows `Steam\steam.exe`.

Together: Cosmo notices Steam, notices a stale winebus, restarts Steam, and the DualSense native bus is what the game actually gets.

## The Witcher 3 / `DUALSENSE=native`

**Stays on `DUALSENSE=native`.** That is the working setup the owner confirmed. Do not switch Witcher to XInput as the “fix.”

## XInput A/B test

**Not needed for this fix.** An earlier session briefly commented out `DUALSENSE=native` for Witcher; under XInput the pad did nothing in-game, then the env was restored. That A/B is closed — native is correct; the bug was stale winebus / missed Steam restart, not “native vs XInput.”

## Real Steam bottle

**No lasting changes from this commit.** The temporary XInput env edit was restored to `DUALSENSE=native` in the earlier investigation. This branch only changes the app (stamp + Steam detect). Nothing written under Application Support for this commit.

## Test

`tests/safety/pad_connect.sh` — after `--pad-connected` flips the bus, asserts `options/.cosmo-winebus-stamp` exists.
