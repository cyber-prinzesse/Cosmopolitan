#!/bin/zsh
# Steam idle diet: when Steam's window is hidden or a game is running, Cosmopolitan puts this bottle's steamwebhelper
# processes into Darwin background QoS; restores when shown / game exits; STEAM_IDLE_DIET=0 opts out; never touches
# another bottle's helpers or a process outside the throwaway folder.
# Stand-ins are native binaries under the bottle path (procFind matches exec path + cwd). COSMO_TEST_STEAM_RUNNING=1
# pretends Steam is up; COSMO_TEST_STEAM_VISIBLE drives the window check. No Wine session required.
# Note: getpriority(PRIO_DARWIN_PROCESS) returns 0 even when Darwin BG is on (macOS 26); assert via Cosmo's
# throttled= line and, once, via CPU share under oversubscription.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
note() { print -r -- "$*" >&2; }
tw_snapshot

clang -O0 -o "$T/native_busy" -xc - <<'C' || fail "build native busy"
#include <stdint.h>
int main(void) { volatile uint64_t x = 0; for (;;) x += x * 7 + 1; return 0; }
C

for b in T U; do
  S="$(tprefix $b)/drive_c/Program Files (x86)/Steam"
  mkdir -p "$S/bin/cef/cef.win64" "$S/steamapps/common/FakeGame" "$(tprefix $b)/options"
  : > "$S/steam.exe"
  cp "$T/native_busy" "$S/bin/cef/cef.win64/steamwebhelper.exe"
  cp "$T/native_busy" "$S/steamapps/common/FakeGame/FakeGame.exe"
done

cp "$T/native_busy" "$T/foreign-steamwebhelper.exe"
"$T/foreign-steamwebhelper.exe" &
FOREIGN=$!
sleep 0.2
kill -0 $FOREIGN 2>/dev/null || fail "foreign helper did not start"

ST="$(tprefix T)/drive_c/Program Files (x86)/Steam"
SU="$(tprefix U)/drive_c/Program Files (x86)/Steam"

# Never wrap a background starter in $(…): the substitution waits for the busy-loop job.
( cd "$ST" && exec "$ST/bin/cef/cef.win64/steamwebhelper.exe" ) &
TP1=$!
( cd "$SU" && exec "$SU/bin/cef/cef.win64/steamwebhelper.exe" ) &
UP1=$!
sleep 0.3
kill -0 $TP1 2>/dev/null || fail "T helper died"
kill -0 $UP1 2>/dev/null || fail "U helper died"
print -r -- "ok: webhelpers T=$TP1 U=$UP1 foreign=$FOREIGN"

# Per-invocation only — never `export` (leaks into later tests in the same shell and makes steamRunning always true).
throttled_of() { print -r -- "$1" | sed -n 's/.*throttled=//p' | tr -d '\r' | head -1; }

note "ct --steam-idle (cold start can take ~20 s)…"
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=0 ct --steam-idle T 2>&1)
note "hidden tick done"
print -r -- "$out" | grep -q "webhelpers=.*$TP1" || fail "Cosmo did not see T helper: $out"
th=$(throttled_of "$out")
[[ "$th" == *"$TP1"* ]] || fail "T not in throttled= when hidden: $out"
[[ "$th" != *"$UP1"* ]] || fail "U appeared in T's throttled list: $out"
[[ "$th" != *"$FOREIGN"* ]] || fail "foreign appeared in throttled list: $out"
print -r -- "ok: hidden → throttled=$th (T only)"

out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=1 ct --steam-idle T 2>&1)
th=$(throttled_of "$out")
[[ -z "$th" ]] || fail "still throttled when visible: $out"
print -r -- "ok: visible → throttled empty"

# Game running (Windows-style argv0 with steamapps\common) → throttle even if visible.
python3 -c "
import os, sys
os.chdir(sys.argv[1])
os.execv(sys.argv[2], [r'C:\\Program Files (x86)\\Steam\\steamapps\\common\\FakeGame\\FakeGame.exe'])
" "$ST/steamapps/common/FakeGame" "$ST/steamapps/common/FakeGame/FakeGame.exe" &
GP=$!
sleep 0.3
kill -0 $GP 2>/dev/null || fail "game stand-in died"
game_busy() { COSMO_TEST_STEAM_RUNNING=1 ct --steam-busy T 2>&1 | grep -q 'busy: a game is running'; }
poll 15 game_busy || fail "expected game busy, got: $(COSMO_TEST_STEAM_RUNNING=1 ct --steam-busy T 2>&1 | grep '^steam in')"
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=1 ct --steam-idle T 2>&1)
th=$(throttled_of "$out")
[[ "$th" == *"$TP1"* ]] || fail "T not throttled while game running: $out"
print -r -- "ok: game running + visible → throttled=$th"

kill -KILL $GP 2>/dev/null
game_idle() { COSMO_TEST_STEAM_RUNNING=1 ct --steam-busy T 2>&1 | grep '^steam in' | grep -q 'idle'; }
poll 15 game_idle || fail "game still busy after kill"
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=1 ct --steam-idle T 2>&1)
th=$(throttled_of "$out")
[[ -z "$th" ]] || fail "still throttled after game exit: $out"
print -r -- "ok: game exit → throttled empty"

# Opt-out.
print 'STEAM_IDLE_DIET=0' > "$(tprefix T)/options/steam.exe.env"
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=0 ct --steam-idle T 2>&1)
print -r -- "$out" | grep -q 'enabled=no' || fail "opt-out not reported: $out"
th=$(throttled_of "$out")
[[ -z "$th" ]] || fail "opt-out still throttled: $out"
print -r -- "ok: STEAM_IDLE_DIET=0 → no throttle"

# Contention: re-enable diet, oversubscribe CPUs, T (BG) should get ~0% while U stays busy.
rm -f "$(tprefix T)/options/steam.exe.env"
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=0 ct --steam-idle T 2>&1)
th=$(throttled_of "$out")
[[ "$th" == *"$TP1"* ]] || fail "re-throttle failed: $out"
ncpu=$(sysctl -n hw.ncpu)
for ((i=0; i<ncpu*2; i++)); do "$T/native_busy" & done
sleep 4
tcpu=$(ps -o pcpu= -p $TP1 | tr -d ' ')
ucpu=$(ps -o pcpu= -p $UP1 | tr -d ' ')
# Kill extras (exact pids we started: children of this shell with our binary path).
ps -axo pid=,command= | awk -v b="$T/native_busy" '$0 ~ b {print $1}' | while read p; do
  [[ $p == $TP1 || $p == $UP1 || $p == $FOREIGN ]] && continue
  kill -KILL $p 2>/dev/null
done
# T should be far below U under oversubscription (Darwin BG).
awk -v t="$tcpu" -v u="$ucpu" 'BEGIN{ exit !(t+0 < 5 && u+0 > 10) }' \
  || fail "contention CPU: T(bg)=$tcpu U=$ucpu (expected T≪U)"
print -r -- "ok: contention T(bg)=${tcpu}% U=${ucpu}%"

kill -KILL $FOREIGN $TP1 $UP1 2>/dev/null
tw_check || fail "your real data changed"
print "PASS steam_idle"
