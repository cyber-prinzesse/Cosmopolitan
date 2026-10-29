# Cursor report: Steam quit stays quit

**Worktree:** `~/Cosmopolitan-cursor`  
**Branch:** `steam-quit-stays-quit` (from `main` @ `131c114`, 1.3.14)  
**Not pushed.** Never touched `~/Cosmopolitan`.

## Trigger (with log evidence)

Two separate mechanisms made Steam “come back” after close/Exit/force-quit.

### 1. Window-close loop — Wine systray hidden

Everyday Steam bottle (`~/Library/Application Support/Cosmopolitan/bottles/Steam/user.reg`):

```
[Software\\Wine\\Systray]
"Hidden"=dword:00000001

[Software\\Wine\\X11 Driver]
"ShowSystray"="false"
```

On Windows, closing Steam’s window minimizes to the tray. With the tray hidden under Wine, the window has nowhere to go and Steam keeps re-showing / respawning webhelper. Cosmopolitan had no `steam://open` / foreground calls; this is Steam+Wine behavior. (Beta bottle had no `Systray` key; Wine 11 may still lack a usable menu-bar tray — not fully verified on device.)

### 2. Cosmopolitan relaunch after Exit — pending / in-flight `restartSteam`

From the everyday bottle’s `logs/bootstrap_log.txt`:

```
[2026-10-29 17:39:41] Shutdown
[2026-10-29 17:39:51] Startup - Steam Client launched with: "...\steam.exe" -no-cef-sandbox -cef-disable-gpu -cef-disable-gpu-compositing -cef-disable-d3d11
```

Ten seconds later, Startup carries Cosmopolitan’s CEF flags and **no** `-applaunch` → Cosmo relaunched Steam (not Steam Play). Same pattern appears many times as Shutdown → Startup +7–10 s with those flags. A following pair (17:40:37 → 17:40:46) has `-applaunch 292030` (intentional Play).

`requestSteamRestart` while busy left `pendingSteamRestart`; when Steam later went idle (or the wait loop woke), Cosmo called `restartSteam` even after the user had Exited. `steamLoopCheck` could also offer “Restart Steam” around quit-time webhelper thrash.

## What changed

| Path | Role |
|------|------|
| `Sources/Features/Stores.swift` | `steamBottleTweaks`: `regDelete` Systray `Hidden`; `ShowSystray=true` |
| `Sources/Features/RegistryLedger.swift` | `regDelete` helper |
| `Sources/Model/Launch.swift` | Run `steamBottleTweaks()` on every `steam.exe` launch (heals existing bottles) |
| `Sources/Model/Model.swift` | `steamStopOwned` / `steamRestartEpoch`; idle-wait cancels pending if Steam is gone; `restartSteam` skips relaunch if epoch bumped |
| `Sources/Model/SteamLaunch.swift` | `noteSteamRunningState`: on user quit (not Cosmo stop), bump epoch + clear pending |
| `Sources/Features/SteamLoop.swift` | Ignore webhelper “loop” when `bootstrap_log` has recent Shutdown with no newer Startup |
| `tests/safety/steam_quit_stays_quit.sh` | Systray heal + pending-quit stays down + Cosmo-owned restart still works |
| `tests/safety/steam_loop.sh` | Deliberate Shutdown is not a loop |

## Test output

```
PASS steam_quit_stays_quit
  ok: steamBottleTweaks cleared Systray Hidden and set ShowSystray=true
  ok: after user quit, pending restart cancelled and Steam stayed down (starts=1)
  ok: Cosmopolitan-owned restartSteam still relaunches Steam (starts=3)

PASS steam_loop
  ok: bootstrap Shutdown (no newer Startup) is not a window loop

PASS steam_restart
PASS steam_launch_options
PASS steam_host_drivers
PASS launchers
```

## Could not verify

- Live tray icon / window-minimize behaviour under Wine 10 and Wine 11 Beta with a real Steam UI (throwaway used a stand-in `steam.exe`; registry heal only).
- Force-quit from Activity Monitor on a real bottle (same quit-edge + pending cancel paths covered with stand-in shutdown).
- Whether Wine 11 Beta without a prior `Systray Hidden` still reopens the window for tray-less minimize (Beta `user.reg` had no Systray key).
