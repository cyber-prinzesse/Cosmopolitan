#!/bin/zsh
# Steam idle diet: when Steam's window is hidden or a game is running, Cosmopolitan puts this bottle's steamwebhelper
# processes on throughput/latency tier 4; restores when shown / game exits; STEAM_IDLE_DIET=0 opts out; never touches
# another bottle's helpers or a process outside the throwaway folder.
# Stand-ins are native binaries under the bottle path (procFind matches exec path + cwd). COSMO_TEST_STEAM_RUNNING=1
# pretends Steam is up; COSMO_TEST_STEAM_VISIBLE drives the window check. No Wine session required.
# Asserts via Cosmo's throttled= line, nice untouched, and CPU share under contention (a throttled helper must not starve).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
note() { print -r -- "$*" >&2; }
tw_snapshot
setopt no_bgnice   # zsh would start the stand-ins at nice 5

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
# Default grace (120 s): a just-started webhelper is never throttled — Steam's window doesn't exist yet while it boots,
# and Darwin BG on a booting helper made Steam report "steamwebhelper is not responding" (2026-10-31).
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=0 ct --steam-idle T 2>&1)
print -r -- "$out" | grep -q "webhelpers=.*$TP1" || fail "Cosmo did not see T helper (grace leg): $out"
[[ -z "$(throttled_of "$out")" ]] || fail "young webhelper throttled during startup grace: $out"
print -r -- "ok: young helper (startup) → not throttled"
# Every later leg drops the grace (stand-ins are seconds old).
export COSMO_TEST_DIET_MIN_AGE=0
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

# Re-enable diet: T throttled, U and the foreign helper untouched; nice never changed (it cannot be undone without root).
rm -f "$(tprefix T)/options/steam.exe.env"
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=0 ct --steam-idle T 2>&1)
th=$(throttled_of "$out")
[[ "$th" == *"$TP1"* && "$th" != *"$UP1"* && "$th" != *"$FOREIGN"* ]] || fail "re-throttle wrong: $out"
niceof() { ps -o nice= -p $1 | tr -d ' '; }
for p in $TP1 $UP1 $FOREIGN; do [[ "$(niceof $p)" == 0 ]] || fail "pid $p nice=$(niceof $p), expected 0"; done
# Contention leg only with COSMO_TEST_HEAVY=1: it saturates every core for 5 s, too much for a Mac someone is using
# (2026-10-31 the user's login broke after a day of heavy tests: cfprefsd kept aborting in _pthread_set_properties_self).
if [[ "$COSMO_TEST_HEAVY" == 1 ]]; then
  # Throttled T must still get a real share under load (Darwin BG gave it ~0%).
  ncpu=$(sysctl -n hw.ncpu); extra=()
  for ((i=0; i<ncpu*2; i++)); do "$T/native_busy" & extra+=$!; done
  sleep 5
  tcpu=$(ps -o pcpu= -p $TP1 | tr -d ' '); ucpu=$(ps -o pcpu= -p $UP1 | tr -d ' ')
  kill -KILL $extra 2>/dev/null
  awk -v t="$tcpu" -v u="$ucpu" 'BEGIN{ exit !(t+0 > u*0.5 && t+0 > 10) }' \
    || fail "throttled helper starved under load: T=$tcpu% U=$ucpu%"
  print -r -- "ok: throttled T not starved under load (T=${tcpu}% U=${ucpu}%), nice untouched"
else
  print -r -- "skip: contention leg (COSMO_TEST_HEAVY=1 runs it)"
fi
out=$(COSMO_TEST_STEAM_RUNNING=1 COSMO_TEST_STEAM_VISIBLE=1 ct --steam-idle T 2>&1)
[[ -z "$(throttled_of "$out")" ]] || fail "not restored when shown: $out"
print -r -- "ok: restored when shown"

kill -KILL $FOREIGN $TP1 $UP1 2>/dev/null
tw_check || fail "your real data changed"
print "PASS steam_idle"
