# Cursor report: scan-no-dupes + ui-speed

**Worktree:** `~/Cosmopolitan-cursor`  
**Branches (separate, not pushed):**  
- `scan-no-dupes` @ `80baf59` (from `main` @ `131c114`)  
- `ui-speed` @ (this commit)  
**Never touched `~/Cosmopolitan`.** Steam-quit / dock-names left on their own branches.

---

## (A) Scan without duplicates — `scan-no-dupes`

### What changed

| Area | Change |
|------|--------|
| `libraryIdentity` / `dedupe` / `dedupeLibrary` | Prefer `steam:<appid>` / `epic:<id>`, then CDPR `red:`, Unreal `ue:`, else real path of app root (case-insensitive). Cross-bottle → one tile + `libraryAlts` for bottle picker. |
| `findApps` | Every bottle; optional folder (CLI `--find` / Advanced picker). Idempotent. |
| Helpers | Expanded `skipExes`; `isHelperExe` drops UnityCrashHandler, EAC/BattlEye, REDprelauncher when the real game exists. |
| Hidden | `cosmopolitan.hidden` identities; “Hide from Library” in the tile menu. |
| Scoring | Size/mtime attribute cache only — no full read of large exes on the main thread. |

### Tests

```
PASS scan_no_dupes   # Witcher×1 across bottles; second --find adds 0; hidden stays hidden
PASS launchers
PASS snapshots
PASS preflight
```

### Could not verify (A)

- Live EA / Ubisoft / Battle.net library manifests in a throwaway bottle (stubs covered naming; install-path discovery still uses existing `storeGames` / Program Files scan).
- User picking an external drive folder in the GUI (CLI `--find` with a folder path covered the same code).

---

## (B) Interface performance — `ui-speed`

### Measurements (test build, 50 stand-in tiles, never the user’s app)

| Scenario | Before (this branch, pre-fix) | After |
|----------|-------------------------------|--------|
| Idle CPU (`sample` + `ps`) | **0.0 %** (repeatForever already fixed in 1.3.6 / `599d723`) | **0.0 %** |
| `--status` scan with 50 games | **0.274 s** | same order (~scan path unchanged on this branch) |
| Window pid ready | **0.21 s** | ≤1 s target met |
| Main thread while idle (`sample` 3 s) | Waiting in `CFRunLoop` / `mach_msg` (healthy) | same |
| Cover decode pressure | `NSImage(contentsOfFile:)` on every tile `body` during scroll; `.id(artVersion)` reset the grid when art arrived | **cached** `coverImage`; art decode off main in `fetchArt`; no per-tile `.id(artVersion)` |
| Cover microbench (200× disk read vs cached buffer) | **20.8 ms** vs **0.0 ms** | documents why cache matters |
| Advanced log pane | `Text(m.log)` re-laid out on every `log +=` | **`logView`**, coalesced ≤4×/s, last 48 KB |

Could not drive a real trackpad scroll in the sandboxed test app without UI automation; scroll fix is the cover/log path above (same class of hitch as the old repeatForever).

### What changed

- `Model.coverImage` + `artCache`; `fetchArt` decodes off the main actor.
- Library / Advanced covers use the cache; removed `.id(m.artVersion)` grid reset.
- `log` still accumulates for CLI/bug report; UI binds `logView` with 250 ms coalesce.
- `verifyAll` yields once before the first launch check so the Library can paint first.

### Tests

```
PASS ui_speed_measure
PASS launchers
PASS log_start
```

### Could not verify (B)

- Instruments Time Profiler UI session (used `sample(1)` instead).
- Hitching while a real game is starting (Wine + Steam) in the throwaway env.
- Exact “main-thread work &lt; 16 ms while scrolling” without a scroll driver; mitigated by removing per-frame image decode and log relayout.
