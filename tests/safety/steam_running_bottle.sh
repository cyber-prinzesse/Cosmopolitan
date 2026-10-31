#!/bin/zsh
# steamRunning is per bottle, also when steam.exe's working folder has left the bottle (seen in $HOME after a Steam self-restart).
# Stand-in: a process named like Wine's steam.exe, working in $T (outside both bottles), with a log open in bottle A's Steam folder.
# A has Steam running; B, with its own wineserver up, must not (the first fallback counted any steam.exe on the Mac: stopSteam(B)
# would then wait 20 s and stop B's programs).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
SP=""
fail() { print "FAIL: $*"; [[ -n "$SP" ]] && kill $SP 2>/dev/null; exit 1; }
tw_snapshot
for b in A B; do ct --newbottle $b >/dev/null 2>&1; [[ -d "$(tprefix $b)/drive_c" ]] || fail "throwaway bottle $b not created"; done
LOG="$(tprefix A)/drive_c/Program Files (x86)/Steam/logs/bootstrap_log.txt"; mkdir -p "${LOG:h}"; : > "$LOG"
for b in A B; do twineserver $b -p 120; done
cd "$T"
python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY); os.set_inheritable(fd, True)
os.execv("/bin/sleep", [r"C:\Program Files (x86)\Steam\steam.exe", "120"])' "$LOG" &
SP=$!
sleep 1; kill -0 $SP 2>/dev/null || fail "stand-in steam.exe did not start"
a=$(ct --steam-busy A 2>&1 | grep '^steam in'); b=$(ct --steam-busy B 2>&1 | grep '^steam in')
[[ "$a" == "steam in A: running"* ]] || fail "A's Steam (log open in A, working folder outside) not seen: '$a'"
print -r -- "ok: $a"
[[ "$b" == "steam in B: not running"* ]] || fail "B looks like it runs Steam because A's does: '$b'"
print -r -- "ok: $b"
kill $SP 2>/dev/null; wait $SP 2>/dev/null; SP=""
for b in A B; do twineserver $b -k 2>/dev/null; done
tw_check || fail "your real data changed"
print "PASS steam_running_bottle"
