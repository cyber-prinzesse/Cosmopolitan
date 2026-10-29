#!/bin/zsh
# Battle.net on Wine 11 (item 3, evidence/t3/bn-args): its Chromium renderer stopped on int3 every ~5 s on r29 — V8 freezes its flags
# page with VirtualProtect(PAGE_READONLY) and CHECKs the old protection was PAGE_READWRITE, which r29 doesn't report — and its GPU
# process couldn't present. The app now starts it on Wine 11 with Chromium in-process on SwiftShader GL and V8's flags left writable
# (Store.battlenet.args, measured: login page on r29), and leaves its HardwareAcceleration setting alone there. This proves the launch
# check says so on Wine 11 and stays green (no more "doesn't start" red), and that Wine 10 is untouched. "fake11" is a stand-in engine
# folder with Wine 11's layout; the launch check only reads the exe. (The real draw: evidence/scripts/t3-bn-switch2.zsh, MODES=ctl.)
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
mkdir -p "$TS/engines/fake11/wswine.bundle/lib/wine/x86_64-unix"; : > "$TS/engines/fake11/wswine.bundle/lib/wine/x86_64-unix/wine"
ct --newbottle BN >/dev/null 2>&1; [[ -d "$(tprefix BN)/drive_c" ]] || fail "throwaway bottle not created"
BND="$(tprefix BN)/drive_c/Program Files (x86)/Battle.net"; mkdir -p "$BND"
print 'int main(void) { return 0; }' > "$T/bn.c"
i686-w64-mingw32-gcc -O2 -s "$T/bn.c" -o "$BND/Battle.net Launcher.exe" || fail "could not build the stand-in exe"

c=$(ct --check BN "$BND/Battle.net Launcher.exe" 2>&1)
[[ "$c" != *"Wine 11"* && "$c" != *"light: red"* ]] || fail "Wine 10: Battle.net must be untouched: $c"
print -r -- "ok: on Wine 10 Battle.net isn't flagged"
defaults write "$TESTID" engine fake11
c=$(ct --check BN "$BND/Battle.net Launcher.exe" 2>&1)
defaults write "$TESTID" engine "$ENGINE"
[[ "$c" == *"starts Battle.net with Chromium in-process for Wine 11"* ]] || fail "Wine 11: the launch check should say how Battle.net starts: $c"
[[ "$c" != *"doesn't start"* && "$c" != *"light: red"* ]] || fail "Wine 11: Battle.net must no longer be red: $c"
print -r -- "ok: on Wine 11 Battle.net starts with Chromium in-process and isn't red"

tw_check || fail "your real data changed"
print "PASS battlenet_wine11"
