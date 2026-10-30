# Steam idle diet (CPU / RAM)

Branch: `steam-idle-diet` (from `origin/main` + cleanup commits from task 1).  
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

This session’s read-only snapshots (Cosmo bottle cwd under `…/bottles/Steam`, three samples ~10 s apart) showed a **live** session (~steam 146 MB / webhelper main ~518 MB / renderers ~522+322 MB) plus a second, idle webhelper tree (~412 MB main) still present — footprint of the live main helper ~615 MB with **WINE_RESERVE ~156 MB clean**.

Mac Steam.app was **not** running during these samples (warning path still implemented).

## Ideas measured

### 1. Steam / CEF switches (client honors)

Strings in the bottle’s `steam.exe` / `libcef.dll` (read-only): `-silent`, `-no-cef-sandbox`, `-cef-disable-gpu`, `-cef-force-gpu`, `-cef-force-accessibility`; Chromium features `enable-low-end-device-mode`, `disable-backgrounding-occluded-windows`, native occlusion helpers. **No** `-cef-force-occlusion` string on this client.

**Rejected for shipping without a throwaway-bottle A/B:** changing Steam flags/registry on the real bottle is off-limits; installing/cloning full Steam into a throwaway and logging in was not completed in this pass. Do not add flags from forum posts alone.

**Optional follow-up for Claude on the real bottle:** one-time restart with `-silent` / low-bandwidth UI settings and re-measure the table above (user-driven; not done here).

### 2. Darwin background QoS while hidden or a game is running — **SHIPPED**

Under CPU oversubscription (`hw.ncpu×2` busy loops), three runs:

| Method | Special process CPU | Others (avg) |
|--------|---------------------|--------------|
| normal | ~45% | ~46% |
| `taskpolicy -b -p` | **~0.3%** | ~48% |
| `taskpolicy -c background` spawn | **~0.3%** | ~48% |
| `nice +20` / renice | ~46% | ~46% (no win on AS) |
| `setpriority(PRIO_DARWIN_PROCESS, pid, 1)` | ~25–30% | no reliable BG |
| SIGSTOP | **0%** | ~48% |

Alone on an idle Mac, BG barely moves the needle (enough cores). **With a game / other load, BG collapses CEF CPU** — the case we care about.

**Implementation:** Cosmopolitan ticks every 5 s with Steam state. When Steam is running in a bottle and (`steamBusy` = game running **or** no on-screen Steam window), it runs `/usr/sbin/taskpolicy -b -p` on that bottle’s `steamwebhelper.exe` pids only (`procFind` under the bottle). Restores with `taskpolicy -B -p` when the window is shown and no game is running. Opt-out: `STEAM_IDLE_DIET=0` on `steam.exe` options or `cosmopolitan.env`. Logged once per on/off. Never touches another bottle or Mac Steam; one-time warning if Mac Steam.app runs alongside a bottle Steam.

`setpriority(…, 1)` alone was **rejected**: it returns success on macOS 26 but does not enter Darwin BG (contention still ~25%+); `taskpolicy -b` does.

UI restore: next 5 s tick clears BG when `COSMO_TEST_STEAM_VISIBLE=1` / window on screen; under contention, BG process was already at ~0.4% and returns to competing fairly after `-B` (product expectation: responsive within ~1 s of show + tick).

### 3. SIGSTOP of renderers for RAM — **REJECTED**

SIGSTOP drives CPU to 0 and would pin RSS, but a stopped CEF renderer stalls IPC (demo: parent writes to a pipe child; child STOPped → no further echo). Risk to overlay / cloud / Steam API paths is unacceptable without a full game + overlay harness. **Not shipped.**

### 4. Wine-side memory (WINE_RESERVE etc.) — **REJECTED**

`footprint` shows large `WINE_RESERVE` (~156 MB clean on the main webhelper). No safe, measurable env/registry knob found that shrinks Steam’s footprint without Wine patches. Left alone.

## Safety test

`tests/safety/steam_idle.sh` — **PASS**

- Hidden → only bottle T’s helper in `throttled=`
- Visible → empty
- Game running (visible) → throttled; game exit → empty
- `STEAM_IDLE_DIET=0` → `enabled=no`, empty
- Foreign helper + bottle U never listed
- Contention: T(bg) **0.4%** vs U **41.4%**

## Re-runs

| Test | Result |
|------|--------|
| steam_idle | PASS |
| steam_restart | PASS |
| steam_loop | PASS |
| launchers | PASS |
| steam_launch_options | **FAIL** (pre-existing on this tree without SteamIdle: `after tunesteam: 111='' 222=''`; reproduced after reverting idle-diet sources) |

No live processes left under `/private/tmp/cosmotest.*` after the suite.

## What Claude should verify on the real bottle

1. With Cosmopolitan running this build, hide Steam’s window (or start a game): webhelper pids under `…/bottles/Steam` should be Darwin BG (`taskpolicy` / Activity Monitor energy). CPU of webhelper main should fall toward the “hidden” baseline or lower under load.
2. Show Steam again with no game: priorities restored; UI usable within ~1 s after the next diet tick (≤5 s).
3. `STEAM_IDLE_DIET=0` in Steam’s options → no BG moves.
4. Optional: confirm Mac Steam warning if `/Applications/Steam.app` is started beside the bottle.
5. Do **not** expect a large RSS drop from this change (CPU/QoS only; SIGSTOP/RAM release rejected).
