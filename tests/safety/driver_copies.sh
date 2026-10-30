#!/bin/zsh
# Phase 0 N1: driver DLLs never land in system32/syswow64. New bottles get none; Wine's automatic prefix update can't add any; the
# cleanup moves out only exact-hash copies of our backend files, restores Wine's own, and lists what it moved. Drivers still load per
# launch from the bottle's drivers/ links.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
R="$TS/engines/renderer"; L="$TS/engines/$ENGINE/wswine.bundle/lib/wine"
ours() { for f in "$R"/*/wine/*/*.dll(N); do shasum -a 256 "$f" | cut -d' ' -f1; done | sort -u; }
copies() { local w="$(tprefix $1)/drive_c/windows" n=0; local o="$(ours)"; for f in "$w"/system32/*.dll(N) "$w"/syswow64/*.dll(N); do print -r -- "$o" | grep -q "$(shasum -a 256 "$f" | cut -d' ' -f1)" && { print "  copy: ${f#$w/}"; (( n++ )); }; done; return $n; }
tw_snapshot

# 1. New bottle: no copies.
ct --newbottle N >/dev/null 2>&1; [[ -d "$(tprefix N)/drive_c" ]] || fail "bottle not created"
copies N || fail "new bottle has driver copies in its system folders"
print "ok: a new bottle has no driver DLLs in system32/syswow64"

# 2. Simulated old bottle: the eight copies the old bottle creation made, plus a look-alike that differs by one byte.
ct --newbottle O >/dev/null 2>&1; W="$(tprefix O)/drive_c/windows"
for d in d3d11 dxgi winemetal; do cp "$R/dxmt/wine/x86_64-windows/$d.dll" "$W/system32/"; done
for d in d3d11 dxgi d3d10core winemetal; do cp "$R/dxmt/wine/i386-windows/$d.dll" "$W/syswow64/"; done
cp "$R/cnc_ddraw/wine/i386-windows/ddraw.dll" "$W/syswow64/"
cp "$R/dxmt/wine/x86_64-windows/d3d10core.dll" "$W/system32/d3d10core.dll"; printf '\x00' | dd of="$W/system32/d3d10core.dll" bs=1 seek=4096 conv=notrunc 2>/dev/null
look=$(shasum -a 256 "$W/system32/d3d10core.dll" | cut -d' ' -f1)
out=$(ct --clean-driver-copies O 2>&1); print -r -- "$out" | grep "moved\|→" | head -12
n=$(print -r -- "$out" | grep -c " → "); [[ $n == 8 ]] || fail "expected 8 copies moved, got $n"
[[ "$(shasum -a 256 "$W/system32/d3d10core.dll" | cut -d' ' -f1)" == "$look" ]] || fail "the one-byte look-alike was touched"
copies O || fail "copies left after cleanup"
for d in d3d11 dxgi; do cmp -s "$W/system32/$d.dll" "$L/x86_64-windows/$d.dll" && cmp -s "$W/syswow64/$d.dll" "$L/i386-windows/$d.dll" || fail "Wine's own $d.dll not restored"; done
cmp -s "$W/syswow64/ddraw.dll" "$L/i386-windows/ddraw.dll" || fail "Wine's own ddraw.dll not restored"
ls "$TS"/_to_delete/*/O/system32/d3d11.dll >/dev/null 2>&1 || fail "moved copies not kept in _to_delete"
print "ok: cleanup moved exactly the 8 copies, restored Wine's own, left the look-alike"

# 3. Drivers still load per launch, from the bottle's drivers/ links.
stress_build O || fail "could not build the stress test programs into the throwaway bottle"; : > "$W/../StressTest/results.txt"
for e in d3d11-64 ddraw-32; do tlaunch O "$W/../StressTest/stress-$e.exe" || fail "stress-$e did not exit within 120 s"; print "  stress-$e exited with code $LAUNCH_CODE after $LAUNCH_TOOK"; done
lnk="$(tprefix O)/drivers/dxmt"; [[ -L "$lnk" && "${lnk:A}" == "${R:A}/dxmt" ]] || fail "no per-bottle drivers/dxmt link to the backend"
grep -c " OK " "$W/../StressTest/results.txt" | grep -q 2 || fail "programs did not render after cleanup: $(cat "$W/../StressTest/results.txt")"
print "ok: D3D11 (DXMT) and DirectDraw (cnc-ddraw) render, loaded from $(tprefix O | sed "s|$T|<tmp>|")/drivers"

# 4. A stale prefix (as after an engine update): the launch updates it without driver slots first, so nothing gets copied in.
print 1 > "$(tprefix O)/.update-timestamp"; tlaunch O "$W/../StressTest/stress-d3d11-64.exe" || fail "launch after the prefix update did not exit within 120 s"; print "  launch with prefix update exited with code $LAUNCH_CODE after $LAUNCH_TOOK"
[[ "$(cat "$(tprefix O)/.update-timestamp")" != 1 ]] || fail "stale prefix was not updated"
copies O || fail "the prefix update copied driver DLLs into the system folders"
print "ok: stale prefix updated before the launch, still no driver copies"
tw_check || fail "your real data changed"
print "PASS driver_copies"
