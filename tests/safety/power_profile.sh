#!/bin/zsh
# A fanless Mac (MacBook Air) gets the cooler profile from the start, not only once it is hot: a 60 fps cap and DXMT at 2/3 resolution
# with MetalFX. FULL_SPEED=1 turns it off for a bottle or a game. Before Play, a Mac short of memory hears which apps use the most and is
# offered to quit them; the test build never quits anything. Fanless and the memory level are simulated (COSMO_TEST_POWER, _MEMLEVEL).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
tw_snapshot
fail() { print "FAIL: $*"; exit 1; }
ct --newbottle B >/dev/null 2>&1; [[ -d "$(tprefix B)/drive_c" ]] || fail "throwaway bottle not created"
dxmt() { COSMO_TEST_POWER=$1 ct --print-env B 2>&1 | grep -E '^DXMT_CONFIG=' }
e=$(dxmt fanless); [[ "$e" == *"preferredMaxFrameRate=60"*"metalSpatialUpscaleFactor=1.5"* ]] || fail "fanless: no cooler profile ($e)"
r=$(COSMO_TEST_POWER=fanless ct --status 2>&1 | sed -n 's/^battery profile: //p'); [[ "$r" == "fanless Mac" ]] || fail "fanless: profile reason '$r'"
h=$(COSMO_TEST_POWER=fanless ct --hints 2>&1); [[ "$h" == *"MacBook Air (no fan)"*"FULL_SPEED=1"* ]] || fail "fanless: launch hint missing: $h"
print -r -- "ok: fanless Mac → profile '$r' from the start ($e)"
[[ -z "$(dxmt plugged)" ]] || fail "plugged in, cool, with a fan: the profile is on"
print "ok: a Mac with a fan, plugged in and cool → no profile"
print "FULL_SPEED=1" >> "$(tprefix B)/cosmopolitan.env"
[[ -z "$(dxmt fanless)" ]] || fail "FULL_SPEED=1 didn't turn the profile off"
print "ok: FULL_SPEED=1 → no profile, even on a fanless Mac"
out=$(COSMO_TEST_MEMLEVEL=80 ct --memcheck 2>&1); [[ "$out" != *"Free memory is low"* ]] || fail "80% free memory was called low"
print "ok: 80% free → Play says nothing"
out=$(COSMO_TEST_MEMLEVEL=12 ct --memcheck 2>&1); line=$(print -r -- "$out" | grep 'Free memory is low (12%) before playing') || fail "12% free: no warning: $(print -r -- "$out" | tail -3)"
[[ "$out" != *"would quit"* ]] || fail "apps were (to be) quit without a yes"
print -r -- "ok: 12% free → ${line:0:160}"
out=$(COSMO_TEST_MEMLEVEL=12 COSMO_TEST_ANSWER=yes ct --memcheck 2>&1)
if [[ "$out" == *"ASK: Quit apps to free memory?"* ]]; then
  [[ "$out" == *"would quit "* ]] || fail "yes, but nothing listed to quit"
  print -r -- "ok: on yes the test build only logs: $(print -r -- "$out" | grep -c 'would quit') app(s) it would quit, none quit"
else print "ok: no app over 300 MB with a Dock icon right now, so no offer (just the warning)"; fi
tw_check || fail "your real data changed"
print "PASS power_profile"
