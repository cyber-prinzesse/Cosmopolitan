# Cursor report: test cleanup Wine orphans

**Worktree:** `~/Cosmopolitan-cursor`  
**Branch:** `test-cleanup-wine-orphans` (from `origin/main` @ `4330f05`) — **not pushed**  
**Never touched `~/Cosmopolitan`, real bottles, or engines** (read-only).

---

## Causes (confirmed before the fix)

### 1. Wine argv never matches `$T/`

HostApp / notepad after CreateProcess:

| pid class | `ps` command | `proc_pidpath` | old argv match |
|-----------|--------------|----------------|----------------|
| wineserver | `$T/…/wineserver` | under `$T/` | yes |
| HostApp / notepad / services… | `C:\Program Files\…` / `C:\windows\…` | under `$T/…/bin/HostApp` or `bin/wine` | **no** |

In a live probe, **9 of 10** processes under the throwaway had Windows argv; only wineserver matched the old `ps -o command= starts with $T/` check.

### 2. Kill-before-`wineserver -k`

Old `testenv_cleanup` TERM/KILL’d argv-matched pids (including wineserver) **first**, then ran `wineserver -k`. With the server already dead, `-k` could not stop the Windows programs. Confirmed: `wineserver -k` while the server is still up clears HostApp+notepad; after killing wineserver first, orphans remain.

---

## Fix (`tests/lib/testenv.sh`)

1. **`_testenv_pids_under_T`**: libproc `proc_listallpids` + `proc_pidpath` (via python3 -I). Keep uid / self-or-ancestor / `$T` shape checks. No broad `pgrep -f` for selection.
2. **`_testenv_kill_checked`**: re-check **executable path** under `$T/` immediately before each signal.
3. **Order**: `wineserver -k` + `-w` (30 s) for each bottle → TERM → KILL leftovers by exe path → print any leftover pid+exe to stderr → `rm -rf "$T"`.
4. **steam_restart / steam_quit_stays_quit / steam_host_drivers**: shut down bottles (`-shutdown` / `twineserver -k`) before EXIT so PASS runs do not rely solely on cleanup for stand-ins.

---

## Tests

```
PASS cleanup_guard
PASS cleanup_orphans   # (a) fail native (b) SIGTERM (d) Wine HostApp+notepad fail() — no exe under $T left
PASS steam_restart
PASS steam_host_drivers
PASS steam_quit_stays_quit
PASS dock_label_child
```

Phase (d) is the regression that failed on argv-only cleanup and passes with this fix.

## Files

- `tests/lib/testenv.sh`
- `tests/safety/cleanup_orphans.sh`, `cleanup_guard.sh`
- `tests/safety/steam_restart.sh`, `steam_quit_stays_quit.sh`, `steam_host_drivers.sh`
- `tests/safety/dock_label_child.sh` (comment only)
- `agents/cursor-report-cleanup-wine.md`

Co-Authored-By: Cursor <noreply@cursor.com>
