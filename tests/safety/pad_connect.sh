#!/bin/zsh
# Item 33: a gamepad connecting switches the bottle's controller bus on for games (DisableHidraw=1, SDL on) when it isn't; when it already
# is, nothing changes. GameController posts the connect notification; --pad-connected runs the same handler.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle P >/dev/null 2>&1; [[ -d "$(tprefix P)/drive_c" ]] || fail "throwaway bottle not created"
K='HKLM\System\CurrentControlSet\Services\winebus'
q() { twine P reg query "$K" /v "$1" 2>/dev/null | tr -d '\r' | grep -o '0x[0-9a-f]*'; }
twine P reg add "$K" /v DisableHidraw /t REG_DWORD /d 0 /f >/dev/null 2>&1; twine P reg add "$K" /v "Enable SDL" /t REG_DWORD /d 0 /f >/dev/null 2>&1
[[ "$(q DisableHidraw)" == 0x0 && "$(q 'Enable SDL')" == 0x0 ]] || fail "could not switch the bus off for the test"
out=$(ct --pad-connected P 2>&1 | grep '^Controller')
[[ "$out" == "Controller test pad connected and switched on for games in P." && "$(q DisableHidraw)" == 0x1 && "$(q 'Enable SDL')" == 0x1 ]] || fail "not switched on: '$out', DisableHidraw $(q DisableHidraw), SDL $(q 'Enable SDL')"
print -r -- "ok: bus off → '$out' (DisableHidraw 0x1, Enable SDL 0x1)"
out=$(ct --pad-connected P 2>&1 | grep '^Controller'); [[ "$out" == "Controller test pad connected." ]] || fail "already on, but: '$out'"
print -r -- "ok: already on → '$out' (nothing changed)"
# Left alone while a game in DualSense native mode runs (its pad goes through raw HID; the bus isn't switched under it).
twine P reg add "$K" /v DisableHidraw /t REG_DWORD /d 0 /f >/dev/null 2>&1; twine P reg add "$K" /v "Enable SDL" /t REG_DWORD /d 0 /f >/dev/null 2>&1
G="$(tprefix P)/drive_c/Program Files/Pad Game"; mkdir -p "$G" "$(tprefix P)/options"
print '#include <windows.h>\nint main(void) { Sleep(60000); return 0; }' > "$T/pad.c"
x86_64-w64-mingw32-gcc -O2 -s "$T/pad.c" -o "$G/Pad Game.exe" || fail "could not build Pad Game"
print 'DUALSENSE=native' > "$(tprefix P)/options/Pad Game.exe.env"
twine P 'C:\Program Files\Pad Game\Pad Game.exe' >/dev/null 2>&1 &
poll 30 pgrep -f 'Pad Game\.exe' || fail "Pad Game did not start"
out=$(ct --pad-connected P 2>&1 | grep '^Controller')
[[ "$out" == "Controller test pad connected." && "$(q DisableHidraw)" == 0x0 ]] || fail "DualSense native game running, but: '$out', DisableHidraw $(q DisableHidraw)"
print -r -- "ok: a game in DualSense native mode is running → '$out' (bus left as it was)"
twineserver P -k
tw_check || fail "your real data changed"
print "PASS pad_connect"
