#!/bin/zsh
# A prefix update that runs out of time (Wine 11's waited for good on a Wine Mono download). Wine writes the new up-to-date stamp when the
# update starts, so the old one has to come back or the half-updated prefix is never updated again. Stopping only the update's
# wineboot/rundll32 leaves the session's boot unfinished and then no new program starts in that bottle until its wineserver ends, so:
#  A. another program runs there (a sleeper stands in for Steam): nothing is touched, the update finishes in the background;
#  B. nothing else runs there: the update's leftovers and that prefix's wineserver go.
# Either way the stamp comes back and the next start updates the prefix. The test build shortens the limit (COSMO_TEST_UPDATE_TIMEOUT).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle U >/dev/null 2>&1; P="$(tprefix U)"; [[ -d "$P/drive_c" ]] || fail "throwaway bottle not created"
print '#include <windows.h>\nint main(void) { Sleep(600000); return 0; }' > "$T/sleep.c"; x86_64-w64-mingw32-gcc -O2 -s "$T/sleep.c" -o "$P/drive_c/sleeper.exe" || fail "no sleeper"
left() { pgrep -f 'rundll32\.exe|wineboot\.exe' | while read p; do [[ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "${P:A}"/* ]] && print $p; done; }
starts() { twine U cmd /c echo started 2>/dev/null | tr -d '\r' | grep -q started; }
L="$TH/Library/Logs/Cosmopolitan.log"

# A. With another program running in the bottle. Started from inside the bottle as the app starts every program (working folder = its
# own folder): the app tells bottles apart by working folder. Started from here it was invisible, and the test only passed while the
# update's own winemenubuilder.exe happened to be counted instead.
# Up means what the app sees: Wine rewrites argv[0] to the Windows command once the program runs (before that the command line is the
# loader's, and the app doesn't count it), and the bottle has finished starting, as with a Steam that has been running.
(cd "$P/drive_c" && twine U 'C:\sleeper.exe') >/dev/null 2>&1 &
inside() { pgrep -f '^C:.sleeper\.exe' | while read p; do [[ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "${P:A}"* ]] && print $p; done; }
up() { [[ -n "$(tserverpid U)" && -n "$(inside)" ]]; }; poll 30 up && poll 60 starts || fail "the sleeper did not start inside the bottle"; ws=$(tserverpid U)
print 1 > "$P/.update-timestamp"
COSMO_TEST_UPDATE_TIMEOUT=2 ct --print-env U >/dev/null 2>&1
grep -q "didn't finish in 2 s; left running because 1 other program" "$L" || fail "A: no log line: $(grep -m1 "didn't finish" "$L")"
[[ "$(cat "$P/.update-timestamp")" == 1 ]] || fail "A: the up-to-date stamp stayed after an unfinished update: $(cat "$P/.update-timestamp")"
kill -0 $ws 2>/dev/null && [[ -n "$(inside)" ]] || fail "A: the wineserver or the other program was stopped"
gone() { [[ -z "$(left)" ]]; }; poll 120 gone || fail "A: the update never finished in the background"; fin=$POLL_TOOK
t1=$EPOCHREALTIME; poll 30 starts || fail "A: programs don't start in the bottle after the update finished"
st=$(printf '%.1f' $(( EPOCHREALTIME - t1 ))); (( st < 60 )) || fail "A: a new program waited $st s to start (the update's boot was cut off)"
print "ok: A. with another program running, the late update was left alone (wineserver pid $ws and the program kept running), finished $fin s later, the stamp came back, a new program started in $st s"
ct --print-env U >/dev/null 2>&1; [[ "$(cat "$P/.update-timestamp")" != 1 ]] || fail "A: the next start did not update the prefix"
print "ok: A. the next start updated the prefix"
twineserver U -k; poll 30 eval '[[ -z "$(tserverpid U)" ]]'

# B. Nothing else running.
print 1 > "$P/.update-timestamp"
COSMO_TEST_UPDATE_TIMEOUT=2 ct --print-env U >/dev/null 2>&1
grep -q "didn't finish in 2 s; it was stopped (nothing else was running there)" "$L" || fail "B: no log line: $(grep "didn't finish" "$L" | tail -1)"
[[ "$(cat "$P/.update-timestamp")" == 1 ]] || fail "B: the up-to-date stamp stayed after an unfinished update"
[[ -z "$(left)" && -z "$(tserverpid U)" ]] || fail "B: leftovers ($(left | tr '\n' ' ')) or the prefix's wineserver ($(tserverpid U)) still running"
ct --print-env U >/dev/null 2>&1; s=$(cat "$P/.update-timestamp"); [[ "$s" != 1 ]] || fail "B: the next start did not update the prefix"
poll 30 starts || fail "B: programs don't start after the update"
print -r -- "ok: B. with nothing else running, the update's leftovers and the prefix's wineserver were stopped; the next start updated it (stamp $s) and programs start"
twineserver U -k
tw_check || fail "your real data changed"
print "PASS prefix_update"
