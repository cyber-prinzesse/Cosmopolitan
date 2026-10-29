#!/bin/zsh
# Ubisoft Connect (item 3): its main window stays blank on our engines unless Chromium draws inside upc.exe itself; with
# "--no-sandbox --in-process-gpu --disable-gpu" it draws on a Wine 11 engine (r29, like CrossOver), never on Wine 10. So on Wine 11
# the app starts upc.exe directly with those switches (the UbisoftConnect.exe stub doesn't pass switches on) and the launch check
# says so; on Wine 10 the launch check is red with the reason. "fake11" is a stand-in engine folder with Wine 11's layout; the
# launch check only reads the exes. (The real draw is measured by evidence/scripts/t3-ubi-redirect.zsh, not here.)
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
mkdir -p "$TS/engines/fake11/wswine.bundle/lib/wine/x86_64-unix"; : > "$TS/engines/fake11/wswine.bundle/lib/wine/x86_64-unix/wine"
ct --newbottle U >/dev/null 2>&1; [[ -d "$(tprefix U)/drive_c" ]] || fail "throwaway bottle not created"
UD="$(tprefix U)/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"; mkdir -p "$UD"
print 'int main(void) { return 0; }' > "$T/s.c"
i686-w64-mingw32-gcc -O2 -s "$T/s.c" -o "$UD/UbisoftConnect.exe" || fail "could not build the stand-in stub"
cp "$UD/UbisoftConnect.exe" "$UD/upc.exe"

c=$(ct --check U "$UD/UbisoftConnect.exe" 2>&1)
[[ "$c" == *"stays blank on Wine 10"* && "$c" == *"light: red"* ]] || fail "Wine 10: Ubisoft Connect should be red with the reason: $c"
print -r -- "ok: on Wine 10 the launch check is red: Ubisoft Connect's window stays blank"
defaults write "$TESTID" engine fake11
c=$(ct --check U "$UD/UbisoftConnect.exe" 2>&1); c2=$(ct --check U "$UD/upc.exe" 2>&1)
defaults write "$TESTID" engine "$ENGINE"
[[ "$c" == *"starts upc.exe with Chromium in-process"* && "$c" != *"stays blank"* && "$c" != *"light: red"* ]] || fail "Wine 11: should start upc.exe in-process, not red: $c"
[[ "$c2" == *"starts upc.exe with Chromium in-process"* ]] || fail "Wine 11: upc.exe itself should get the same treatment: $c2"
print -r -- "ok: on Wine 11 both UbisoftConnect.exe and upc.exe start upc.exe with Chromium in-process, not red"

# The stub without upc.exe beside it (a broken install) is left alone: no redirect target, no Ubisoft note.
rm "$UD/upc.exe"; c=$(ct --check U "$UD/UbisoftConnect.exe" 2>&1)
[[ "$c" != *"upc.exe"* ]] || fail "no upc.exe beside the stub, yet it was treated as Ubisoft Connect: $c"
print -r -- "ok: no upc.exe beside the stub — no redirect, no note"

tw_check || fail "your real data changed"
print "PASS ubisoft_wine11"
