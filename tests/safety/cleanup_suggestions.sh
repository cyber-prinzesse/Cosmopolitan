#!/bin/zsh
# Item 36: cleanup suggestions by size. A throwaway bottle gets the shader cache of a game that is gone (app 777) and of one still installed
# (app 888), a leftover installer, and Windows and user temp files. The list shows them biggest first, without the installed game's cache;
# nothing is deleted without confirmation (--apply alone deletes nothing); confirmed, exactly the listed items go,
# except a bottle's temp files while a program runs in it.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle Z >/dev/null 2>&1; [[ -d "$(tprefix Z)/drive_c" ]] || fail "throwaway bottle not created"
C="$(tprefix Z)/drive_c"; A="$C/Program Files (x86)/Steam/steamapps"; U=$(ls "$C/users" | grep -v Public | head -1)
mkdir -p "$A/shadercache/777" "$A/shadercache/888" "$(tprefix Z)/installers" "$C/windows/temp" "$C/users/$U/AppData/Local/Temp"
mk() { head -c $(( $2 * 1048576 )) /dev/urandom > "$1"; }
mk "$A/shadercache/777/cache.bin" 6; mk "$A/shadercache/888/cache.bin" 9; print '"AppState"{"appid" "888"}' > "$A/appmanifest_888.acf"
mk "$(tprefix Z)/installers/SteamSetup.exe" 2; mk "$C/windows/temp/w.tmp" 1; mk "$C/users/$U/AppData/Local/Temp/u.tmp" 4
list=$(ct --cleanup-suggestions 2>&1 | grep '^could go: ')
print -r -- "$list" | sed 's/^/  /'
order=$(print -r -- "$list" | sed -n 's/^could go: [0-9]* \([A-Za-z]*\).*/\1/p' | tr '\n' ' ')
[[ "$list" == *"(Steam app 777)"* && "$list" != *"(Steam app 888)"* && "$list" == *"Leftover installer SteamSetup.exe"* && "$list" == *"Windows temp files (bottle Z)"* && "$list" != *"Windows user"* ]] || fail "wrong list"
[[ "$order" == "Shader Windows Leftover "* ]] || fail "not biggest first: $order"
print "ok: biggest first, the installed game's cache (app 888) not offered"
out=$(ct --cleanup-suggestions --apply 2>&1 | grep 'nothing deleted'); [[ -n "$out" && -f "$A/shadercache/777/cache.bin" ]] || fail "--apply without --yes deleted something"
print "ok: without confirmation nothing is deleted ($out)"
# While a program runs in the bottle its temp files stay (an installer may still need them); everything else confirmed goes.
print '#include <windows.h>\nint main(void) { Sleep(60000); return 0; }' > "$T/sleep.c"; x86_64-w64-mingw32-gcc -O2 -s "$T/sleep.c" -o "$C/sleeper.exe" || fail "could not build the sleeper"
twine Z 'C:\sleeper.exe' >/dev/null 2>&1 &
poll 30 pgrep -f 'sleeper\.exe' || fail "the sleeper did not start"
out=$(ct --cleanup-suggestions --apply --yes 2>&1)
[[ ! -e "$A/shadercache/777" && ! -e "$(tprefix Z)/installers/SteamSetup.exe" && -f "$C/windows/temp/w.tmp" && "$out" == *"Kept Windows temp files (bottle Z): a program is running there."* ]] || fail "with a program running: $(print -r -- "$out" | grep -E 'Kept|Freed')"
print -r -- "ok: a program running in the bottle → $(print -r -- "$out" | grep -c '^Kept') temp folders kept, the rest removed"
twineserver Z -k; poll 30 zsh -c '! pgrep -f "sleeper\.exe"' || fail "the sleeper did not stop"
ct --cleanup-suggestions --apply --yes >/dev/null 2>&1
[[ ! -e "$A/shadercache/777" && ! -e "$(tprefix Z)/installers/SteamSetup.exe" && -z "$(ls "$C/windows/temp")" && -z "$(ls "$C/users/$U/AppData/Local/Temp")" ]] || fail "confirmed items were not all removed"
[[ -f "$A/shadercache/888/cache.bin" && -d "$C/windows/temp" ]] || fail "something not listed was removed"
print "ok: confirmed, exactly the listed items went (temp folders emptied, the installed game's cache kept)"
tw_check || fail "your real data changed"
print "PASS cleanup_suggestions"
