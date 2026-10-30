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
tw_check
print "PASS steam_dock_addon"
