#!/bin/zsh
# Battle.net on Wine 11 (item 3, evidence item3a): its 32-bit Chromium GPU process exits on the Wine 11 beta (r29: endless spinner),
# while Wine 10 draws it. The engine is app-wide, so (1) switching from Wine 10 to Wine 11 must ask first when any bottle has Battle.net,
# and cancelling keeps Wine 10; with no Battle.net anywhere it must not ask; and (2) on Wine 11 the launch check lights Battle.net red
# with the reason, while on Wine 10 the same exe is not flagged. "fake11" is a stand-in engine folder with Wine 11's layout
# (lib/wine/x86_64-unix/wine, what engineIsWine11 looks for): nothing runs on it, the launch check only reads the exe.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
mkdir -p "$TS/engines/fake11/wswine.bundle/lib/wine/x86_64-unix"; : > "$TS/engines/fake11/wswine.bundle/lib/wine/x86_64-unix/wine"
ct --newbottle Plain >/dev/null 2>&1; [[ -d "$(tprefix Plain)/drive_c" ]] || fail "throwaway bottle not created"

# No Battle.net in any bottle: Wine 10 → Wine 11 switches without a question.
c=$(ct --engine-switch-check fake11 2>&1)
[[ "$c" == *"→ fake11: yes"* && "$c" != *"ASK:"* ]] || fail "no Battle.net bottle, yet the switch asked or refused: $c"
print -r -- "ok: no Battle.net anywhere — switching to Wine 11 doesn't ask"

# A bottle with Battle.net: the switch asks, names the bottle, and Cancel keeps Wine 10.
ct --newbottle BN >/dev/null 2>&1; [[ -d "$(tprefix BN)/drive_c" ]] || fail "second throwaway bottle not created"
BND="$(tprefix BN)/drive_c/Program Files (x86)/Battle.net"; mkdir -p "$BND"
print 'int main(void) { return 0; }' > "$T/bn.c"
i686-w64-mingw32-gcc -O2 -s "$T/bn.c" -o "$BND/Battle.net Launcher.exe" 2>/dev/null || x86_64-w64-mingw32-gcc -O2 -s "$T/bn.c" -o "$BND/Battle.net Launcher.exe" || fail "could not build the stand-in exe"
c=$(ct --engine-switch-check fake11 2>&1)
[[ "$c" == *"ASK: Battle.net doesn't start on Wine 11 yet"* && "$c" == *"BN"* ]] || fail "switch to Wine 11 with a Battle.net bottle didn't ask (or didn't name it): $c"
[[ "$c" == *"kept $ENGINE"* ]] || fail "Cancel must keep the Wine 10 engine: $c"
print -r -- "ok: with Battle.net in bottle BN, switching to Wine 11 asks and Cancel keeps $ENGINE"
c=$(COSMO_TEST_ANSWER=yes ct --engine-switch-check fake11 2>&1)
[[ "$c" == *"→ fake11: yes"* ]] || fail "'Switch anyway' must switch: $c"
print -r -- "ok: 'Switch anyway' switches"
c=$(ct --engine-switch-check "$ENGINE" 2>&1)
[[ "$c" == *": yes"* && "$c" != *"ASK:"* ]] || fail "staying on Wine 10 must not ask: $c"
print -r -- "ok: Wine 10 → Wine 10 doesn't ask"

# Launch check: Wine 10 doesn't flag Battle.net; Wine 11 lights it red with the reason.
c=$(ct --check BN "$BND/Battle.net Launcher.exe" 2>&1)
[[ "$c" != *"Wine 11"* ]] || fail "Wine 10 launch check flagged Battle.net: $c"
print -r -- "ok: on Wine 10 Battle.net isn't flagged"
defaults write "$TESTID" engine fake11
c=$(ct --check BN "$BND/Battle.net Launcher.exe" 2>&1)
defaults write "$TESTID" engine "$ENGINE"
[[ "$c" == *"Battle.net doesn't start on Wine 11 yet"* && "$c" == *"light: red"* ]] || fail "Wine 11 launch check should be red with the reason: $c"
print -r -- "ok: on Wine 11 the launch check is red: Battle.net doesn't start on Wine 11 yet"

tw_check || fail "your real data changed"
print "PASS battlenet_wine11"
