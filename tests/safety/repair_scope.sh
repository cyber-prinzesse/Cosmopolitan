#!/bin/zsh
# Regression for Phase 0 N5: Repair stops only the bottle it repairs. Another bottle's Wine programs, a Mac process with ".exe" in its
# command line, your Steam and your app must survive. Troubleshoot must not ask for Repair just because two bottles are running.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle A >/dev/null 2>&1; ct --newbottle B >/dev/null 2>&1
[[ -d "$(tprefix A)/drive_c" && -d "$(tprefix B)/drive_c" ]] || fail "throwaway bottles not created"
(twine A notepad >/dev/null 2>&1 &); (twine B notepad >/dev/null 2>&1 &)
perl -e 'sleep 600' decoy.exe >/dev/null 2>&1 & decoy=$!
trap 'kill $decoy 2>/dev/null; testenv_cleanup' EXIT
both_up() { [[ -n "$(tserverpid A)" && -n "$(tserverpid B)" ]]; }
poll 120 both_up || fail "wineservers did not start within 120 s"; print "ok: both bottles' wineservers up after ${POLL_TOOK} s"
sa=$(tserverpid A) sb=$(tserverpid B)
ts=$(ct --troubleshoot A 2>&1)
print -r -- "$ts" | grep -q "This bottle's Wine server is Cosmopolitan's engine" || fail "troubleshoot did not identify bottle A's own server"
print -r -- "$ts" | grep -q -i "one wineserver\|kills all wine" && fail "troubleshoot still counts wineservers across bottles"
print -r -- "$ts" | grep "^✗.*Repair" | grep -v -i "DisableHidraw\|DPI\|Steam" && fail "troubleshoot suggests Repair for running bottles"
ct --repair A >/dev/null 2>&1
a_gone() { [[ -z "$(tserverpid A)" ]]; }
poll 120 a_gone || fail "bottle A's wineserver survived its own Repair (waited 120 s)"; print "ok: bottle A's wineserver gone ${POLL_TOOK} s after Repair returned"
kill -0 "$sb" 2>/dev/null || fail "bottle B's wineserver was killed by A's Repair"
kill -0 "$decoy" 2>/dev/null || fail "a Mac process with .exe in its command line was killed"
kill "$decoy" 2>/dev/null
tw_check || fail "your real data changed"
print "PASS repair_scope: Repair stopped only bottle A (B's server $sb and the decoy survived)"
