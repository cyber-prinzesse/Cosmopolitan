#!/bin/zsh
# --launch keeps its old fixed-time default (exit 0); --launch … --wait [seconds] returns the program's own exit code, or 124 if it is still
# running at the limit, and the program keeps running after the CLI stops waiting (its output goes to the log file, not to a pipe that
# dies with the CLI). The test program prints a tick every 0.5 s for 8 s, writes done.txt and exits with code 7.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle W >/dev/null 2>&1; [[ -d "$(tprefix W)/drive_c" ]] || fail "throwaway bottle not created"
D="$(tprefix W)/drive_c/StressTest"; mkdir -p "$D"
cat > "$T/sleeper.c" <<'C'
#include <stdio.h>
#include <windows.h>
int main(void) {
    for (int i = 0; i < 16; i++) { printf("sleeper tick %d\n", i); fflush(stdout); Sleep(500); }
    FILE *f = fopen("C:\\StressTest\\done.txt", "w"); if (f) { fputs("done\n", f); fclose(f); }
    return 7;
}
C
x86_64-w64-mingw32-gcc -O2 -s "$T/sleeper.c" -o "$D/sleeper.exe" || fail "could not build the test program"
running() { pgrep -f 'StressTest.sleeper\.exe' | head -1; }
finished() { [[ -f "$D/done.txt" ]]; }
gone() { [[ -z "$(running)" ]]; }
took() { printf '%.1f' $(( EPOCHREALTIME - $1 )); }

t0=$EPOCHREALTIME; ct --launch W "$D/sleeper.exe" --wait 60 > "$T/w60.out" 2>&1; rc=$?
(( rc == 7 )) || fail "--wait 60 returned $rc, expected the program's own exit code 7: $(grep '^launch:' "$T/w60.out")"
finished || fail "--wait 60 returned before the program finished"
print "ok: --wait 60 returned the program's own exit code 7 after $(took $t0) s ($(grep '^launch:' "$T/w60.out"))"
rm -f "$D/done.txt"; poll 30 gone

t0=$EPOCHREALTIME; ct --launch W "$D/sleeper.exe" --wait 2 > "$T/w2.out" 2>&1; rc=$?; t=$(took $t0)
(( rc == 124 )) || fail "--wait 2 returned $rc, expected 124 (still running at the limit)"
pid=$(running); [[ -n "$pid" ]] || fail "the program died when the CLI stopped waiting"
finished && fail "the program had already finished; the test needs it running past the limit"
print "ok: --wait 2 returned 124 after $t s ($(grep '^launch:' "$T/w2.out")); the CLI has exited and the program is still running (pid $pid)"
poll 60 finished || fail "the program never finished after the CLI stopped waiting"
print "ok: the program kept running without the CLI and finished on its own ${POLL_TOOK} s later (wrote done.txt)"
grep -q 'sleeper tick 15' "$TH/Library/Logs/Cosmopolitan.log" || fail "the program's last output did not reach the log"
print "ok: its output after the CLI exited reached the log (last line: $(grep 'sleeper tick' "$TH/Library/Logs/Cosmopolitan.log" | tail -1))"
rm -f "$D/done.txt"; poll 30 gone

t0=$EPOCHREALTIME; ct --launch W "$D/sleeper.exe" 3 > "$T/d3.out" 2>&1; rc=$?
(( rc == 0 )) || fail "the default --launch returned $rc; the old behaviour returns 0"
print "ok: default --launch (no --wait) kept its old behaviour: fixed 3 s run, exit 0 after $(took $t0) s"
poll 30 gone; finished && print "  (in the default mode the program finished anyway)" || print "  (in the default mode the program stopped when the CLI exited: its output pipe closed — the old behaviour, unchanged)"
tw_check || fail "your real data changed"
print "PASS launch_wait"
