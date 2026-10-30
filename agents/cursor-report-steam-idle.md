# Steam idle diet (CPU / RAM)

Branch: `steam-idle-diet` (rebased onto `origin/main` @ `252099a` / 1.3.19).  
Cleanup commits kept: harden testenv kill guard + zsh trap holder.  
Real Cosmopolitan Steam bottle: **read-only** (ps / top / footprint / vmmap only). No signals, renice, or file/registry writes.

## Baseline (real bottle, 2026-10-30, idle, no game)

Claude’s earlier session numbers (window visible vs hidden) stand as the product baseline:

| Process | RSS (approx) | CPU visible | CPU hidden |
|--------|--------------|-------------|------------|
| steam.exe | 151 MB | — | — |
| steamwebhelper main | 458 MB | ~41% | ~22% |
| renderer ×2 | 512 + 407 MB | ~15–18% | ~15–18% |
| utility ×2 | 96 + 69 MB | — | — |
| SteamService | 24 MB | — | — |
| wineserver | 32 MB | — | — |
| **Total** | **~1.7 GB** | | |

This session’s read-only snapshots (Cosmo bottle cwd under `…/bottles/Steam`) showed a live session plus a second idle webhelper tree; footprint of the live main helper ~615 MB with **WINE_RESERVE ~156 MB clean**.

## Ideas measured

### 1. Steam / CEF switches — not shipped without throwaway A/B

Strings present: `-silent`, `-cef-disable-gpu`, etc. No `-cef-force-occlusion` on this client. Unmeasured flags not added.

### 2. Darwin background QoS while hidden or a game is running — **SHIPPED**

Under CPU oversubscription (`hw.ncpu×2` busy loops): `taskpolicy -b -p` → ~0.3% vs ~48% for normals. `setpriority(PRIO_DARWIN_PROCESS, pid, 1)` does **not** enter Darwin BG on macOS 26. SIGSTOP → 0% but rejected (IPC stall).

**Implementation:** 5 s tick with Steam state. When enabled and (game running **or** Steam window not on screen), `/usr/sbin/taskpolicy -b -p` on that bottle’s `steamwebhelper.exe` pids only (`procFind` under the bottle). Restore with `-B` when shown and idle. Opt-out: `STEAM_IDLE_DIET=0`. Mac Steam one-shot warning.

**Review fix:** `taskpolicy` is only run for **newly seen** pids and on throttle on/off — not every 5 s for every tracked pid. Each call launches a process (not a cheap syscall).

### 3. SIGSTOP of renderers — **REJECTED** (IPC stall)

### 4. Wine WINE_RESERVE — **REJECTED** (no safe knob)

## `steam_launch_options` false alarm

Earlier “FAIL after tunesteam: LaunchOptions empty” was **not** caused by cleanup or SteamIdle.  
`steam_idle.sh` had used `export COSMO_TEST_STEAM_RUNNING=1`, which leaked in the agent shell; every later `ct` saw `steamRunning == true` and skipped writing LaunchOptions. Reproduced the same FAIL on clean `origin/main` with that env set.

**Fix:** per-invocation `COSMO_TEST_STEAM_RUNNING=1 … ct …` only — never `export`. After clearing the leak, `steam_launch_options` **PASS**es on this branch.

## Broad / pattern kills used this session (2026-10-30)

These violated the exact-pid / own-`$T` rule during hung-debug cleanup and must not be repeated:

| When (approx local) | What |
|---------------------|------|
| ~12:19–12:55 | `pkill -KILL -f '/private/tmp/winown'` while clearing stuck CGWindow probes |
| ~12:40–13:00 | loops over `ps`/`lsof` killing any pid whose cwd was under `/private/tmp/cosmotest.*` (all leftover test dirs, not only the current `$T`) |
| ~12:40–13:00 | `kill -KILL` on pids matched by awk `/\/private\/tmp\/cosmotest\./` in the command line |
| ~12:40 | `rm -rf /private/tmp/cosmotest.*` after those kills |

Correct pattern going forward: exact pids this run started, or `testenv_cleanup` for this run’s `$T` only. No `pkill`/`killall`/`pgrep -f` patterns.

## Tests (after rebase + fixes)

| Test | Result |
|------|--------|
| steam_idle | PASS (contention T 0.3% vs U 33.6%) |
| steam_launch_options | PASS |
| steam_restart | PASS |
| steam_loop | PASS |
| launchers | PASS |
| steam_dock_addon | PASS |

## What Claude should verify on the real bottle

1. Hide Steam or start a game → bottle webhelpers in Darwin BG; CPU drops under load.
2. Show Steam, no game → priorities restored; UI usable within ~1 s after the next diet tick (≤5 s).
3. `STEAM_IDLE_DIET=0` → no BG moves.
4. Optional: Mac Steam warning if `/Applications/Steam.app` runs beside the bottle.
5. No large RSS drop expected (CPU/QoS only).
