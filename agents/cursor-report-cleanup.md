# Cursor report: test-cleanup-orphans

**Worktree:** `~/Cosmopolitan-cursor`  
**Branch:** `test-cleanup-orphans` (from `origin/main`)  
**Not pushed.** Never touched `~/Cosmopolitan` / real bottles.

---

## Incident 2026-10-30 11:31:15

First draft of `_testenv_pgrep_re` used:

```sh
sed -e 's/[][\\.?*+^$(){}|/]/g'
```

On macOS that `sed` fails (`unescaped newline inside substitute pattern`) and printed nothing. `testenv_cleanup` then ran `pgrep -f "^/"` and sent **SIGTERM**, then **SIGKILL**, to every user process whose command line starts with `/`.

That killed Dock, Finder, ControlCenter, ~40 launchd agents, Cosmopolitan, the bottle’s `steam.exe`, other apps, and a parallel Claude session. The user’s screen went black. This violated the off-limits rule (no signals outside the throwaway folder).

### Hardening (this commit)

1. **Strict `$T`:** must match `^/private/tmp/cosmotest\.[A-Za-z0-9]{6}$` or kill is refused (`cleanup: refusing to kill (bad pattern)`).
2. **Pure zsh pattern:** `^/private/tmp/cosmotest\.${T:t:e}/` — no sed/python escape (mktemp suffix is alphanumeric only).
3. **Per-pid checks before every signal:** re-read `ps -o command=`; must start with `$T/`; uid must be ours; never `$$` / `$PPID` / ancestors (`_testenv_kill_checked`).
4. **`tests/safety/cleanup_guard.sh`:** asserts zero pids for unset/empty/`/`/`/private/tmp/cosmotest.`/wrong prefix/etc., and only a dummy under a valid `$T`. Run this **before** `cleanup_orphans`.
5. Traps: `eval "$(testenv_trap_cleanup)"` after `testenv_init` (cannot set `EXIT` inside a function — zsh would fire it on function return). INT/TERM: cleanup then `kill -KILL $$` (zsh often ignores `exit` in a signal trap during `sleep`).

---

## Tests (Dock / Finder / Cosmo pids unchanged)

| Check | Before | After |
|-------|--------|-------|
| Dock | 44567 | 44567 |
| Finder | 44572 | 44572 |
| Cosmopolitan | 45187 | 45187 |

```
PASS cleanup_guard
PASS cleanup_orphans   # fail() path + SIGTERM (Python holder; see note) + foreign cosmotest control survives
PASS fault_loop
PASS crash_capture
PASS steam_loop
```

`pgrep -fl /private/tmp/cosmotest` after the suite: **empty** (no live processes).

### SIGTERM note

Under this agent runner, **zsh** traps for TERM/INT/USR1 did not run (process stayed in `sleep`; marker files never written). **Python** `signal.SIGTERM` handlers work. Phase (b) of `cleanup_orphans` therefore uses a Python mid-run holder whose SIGTERM handler invokes `testenv_cleanup` in zsh — same cleanup code path, signal delivered to a process that actually handles it. Everyday tests still arm zsh traps via `eval "$(testenv_trap_cleanup)"` for normal EXIT / interactive Ctrl-C.

---

## Leftover `/private/tmp/cosmotest.*` directories (not deleted)

Empty/abandoned folders from prior runs (including the incident and probes). Listed only; not removed:

`0G5QjB` `0g795A` `7vnVBa` `a95Gd6` `Drkdh6` `Ee0HWh` `FP3g7B` `getmkt` `haB8ZU` `L5VaU5` `Lh8pvp` `pTpsXQ` `RkX7BI` `VFmkGZ` `wc8wWM` `XcVhtv` `xivw9F` `xM3QrG` `yINQd6` `zdj7cQ`

---

## Files

- `tests/lib/testenv.sh` — safe pid selection + cleanup + trap helper  
- `tests/safety/cleanup_guard.sh` — no-kill guard  
- `tests/safety/cleanup_orphans.sh` — fail / SIGTERM / control  
- All safety/stress/ui tests: `eval "$(testenv_trap_cleanup)"` after init  
