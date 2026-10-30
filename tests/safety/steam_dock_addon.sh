#!/bin/zsh
# One Dock icon for Steam: the app makes the engine's Mac driver load cosmo_nodock.dylib (NoDockAddon.swift), and a program with
# Mac Driver › NoDockIcon=y then gets no Dock icon while its window still shows. Throwaway engine copy and bottle only.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
E="$TS/engines/$ENGINE/wswine.bundle"; U="$E/lib/wine/x86_64-unix"
# Start from the engine's own driver (the real engine may already carry the add-on).
[[ -f "$U/winemac.so.orig-before-nodock" ]] && { cp "$U/winemac.so.orig-before-nodock" "$U/winemac.so"; rm -f "$U/winemac.so.orig-before-nodock"; }
rm -f "$U/cosmo_nodock.dylib"
otool -L "$U/winemac.so" | grep -q cosmo_nodock && fail "test engine's driver already loads the add-on"
out=$(ct --nodock-engine "$E" 2>&1)
[[ "$out" == *"now honours NoDockIcon"* ]] || fail "add-on not installed: $out"
otool -L "$U/winemac.so" | grep -q '@loader_path/cosmo_nodock.dylib' || fail "winemac.so doesn't load the add-on"
[[ -f "$U/cosmo_nodock.dylib" && -f "$U/winemac.so.orig-before-nodock" ]] || fail "add-on or backup missing"
codesign -v "$U/winemac.so" "$U/cosmo_nodock.dylib" || fail "signature invalid"
h=$(shasum "$U/winemac.so"); out=$(ct --nodock-engine "$E" 2>&1)
[[ "$(shasum "$U/winemac.so")" == "$h" && "$out" != *"Dock icon"* ]] || fail "second run changed the driver: $out"
print "ok: engine's Mac driver loads cosmo_nodock.dylib (signed, backup kept); a second run changes nothing"

ct --newbottle Q >/dev/null 2>&1; [[ -d "$(tprefix Q)/drive_c" ]] || fail "throwaway bottle Q not created"
dock_type() {   # starts notepad in Q, prints its LaunchServices type, stops the bottle
  twine Q notepad.exe >/dev/null 2>&1 &
  local p="" i; for i in {1..30}; do sleep 0.5; p=$(ps -axo pid=,command= | awk '/notepad\.exe/ && !/awk/ {print $1; exit}'); [[ -n "$p" ]] && lsappinfo list | grep "pid = $p " | grep -q 'type="\(Foreground\|UIElement\)"' && break; done
  lsappinfo list | grep "pid = $p " | grep -o 'type="[^"]*"'; twineserver Q -k; sleep 1; }
t=$(dock_type); [[ "$t" == 'type="Foreground"' ]] || fail "without NoDockIcon notepad should be a Dock app: $t"
twine Q reg add 'HKCU\Software\Wine\AppDefaults\notepad.exe\Mac Driver' /v NoDockIcon /d y /f >/dev/null 2>&1; twineserver Q -w
t=$(dock_type); [[ "$t" == 'type="UIElement"' ]] || fail "with NoDockIcon notepad should have no Dock icon: $t"
print "ok: NoDockIcon=y → no Dock icon (UIElement); without it a normal Dock app"
# Dock names: a Steam game gets its own name in options/dock-names.txt (scan), and the add-on applies a listed name.
S="$(tprefix Q)/drive_c/Program Files (x86)/Steam/steamapps"; mkdir -p "$S/common/FakeW"
cp "$(tprefix Q)/drive_c/windows/system32/notepad.exe" "$S/common/FakeW/fakew.exe"
printf '"AppState"\n{\n\t"appid"\t\t"9"\n\t"name"\t\t"Fake Witcher: Wild \u2014 Hunt"\n\t"installdir"\t\t"FakeW"\n\t"StateFlags"\t\t"4"\n}\n' > "$S/appmanifest_9.acf"
ct --status Q >/dev/null 2>&1
grep -qx $'fakew.exe\tFake Witcher: Wild \u2014 Hunt' "$(tprefix Q)/options/dock-names.txt" || fail "dock-names.txt lacks the Steam game: $(cat "$(tprefix Q)/options/dock-names.txt" 2>&1)"
print "ok: scan wrote the Steam game's Dock name to options/dock-names.txt"
# CDPR: launcher-configuration.json → game exe gets the Steam title; shared REDlauncher.exe (outside the game folder) → "REDlauncher".
W="$S/common/The Witcher 3"; mkdir -p "$W/bin/x64_dx12"
cp "$(tprefix Q)/drive_c/windows/system32/notepad.exe" "$W/REDprelauncher.exe"
cp "$(tprefix Q)/drive_c/windows/system32/notepad.exe" "$W/bin/x64_dx12/witcher3.exe"
print '{"fallback":"DirectX 12","executables":[{"description":"DirectX 12","executable":{"directoryPath":"bin\\\\x64_dx12","fileName":"witcher3.exe"}}]}' > "$W/launcher-configuration.json"
printf '"AppState"\n{\n\t"appid"\t\t"292030"\n\t"name"\t\t"The Witcher 3: Wild Hunt \u2014 Remastered"\n\t"installdir"\t\t"The Witcher 3"\n\t"StateFlags"\t\t"4"\n}\n' > "$S/appmanifest_292030.acf"
ct --status Q >/dev/null 2>&1
DN="$(tprefix Q)/options/dock-names.txt"
grep -qx $'redlauncher.exe\tREDlauncher' "$DN" || fail "dock-names.txt lacks shared redlauncher.exe: $(cat "$DN" 2>&1)"
grep -qx $'witcher3.exe\tThe Witcher 3: Wild Hunt \u2014 Remastered' "$DN" || fail "dock-names.txt lacks witcher3.exe: $(cat "$DN" 2>&1)"
grep -qx $'redprelauncher.exe\tThe Witcher 3: Wild Hunt \u2014 Remastered' "$DN" || fail "dock-names.txt lacks redprelauncher.exe: $(cat "$DN" 2>&1)"
print "ok: CDPR layout → redlauncher.exe=REDlauncher, witcher3.exe + redprelauncher.exe = game name"
twine Q reg delete 'HKCU\Software\Wine\AppDefaults\notepad.exe\Mac Driver' /v NoDockIcon /f >/dev/null 2>&1; twineserver Q -w
print $'notepad.exe\tSolo Name \u2014 Test' >> "$(tprefix Q)/options/dock-names.txt"
dock_name() {   # starts notepad in Q, prints its Dock name, stops the bottle
  twine Q notepad.exe >/dev/null 2>&1 &
  local p="" n="" i; for i in {1..30}; do sleep 0.5; p=$(ps -axo pid=,command= | awk '/notepad\.exe/ && !/awk/ {print $1; exit}'); [[ -n "$p" ]] && n=$(lsappinfo list | awk -v k="pid = $p " '/^ *[0-9]+\) /{l=$0} index($0,k){print l}' | sed -n 's/^ *[0-9]*) "\(.*\)" ASN.*/\1/p'); [[ "$n" == *Solo* ]] && break; done
  print -r -- "$n"; twineserver Q -k; sleep 1; }
n=$(dock_name); [[ "$n" == $'Solo Name \u2014 Test' ]] || fail "listed Dock name not applied: '$n'"
print "ok: the add-on names the program from dock-names.txt ('$n')"
tw_check
print "PASS steam_dock_addon"
