#!/bin/zsh
# Item 27: a game that crashes within 30 s is retried once with the next driver (DXMT → D3DMetal → DXVK, the decision engine's row 12); the
# working driver is remembered in its Options and named in the compat report; a game that crashes with that one too goes back to automatic;
# a driver the user chose themselves is asked about, never switched silently. Stand-in Direct3D 11 programs: one exits with code 3 when
# DXMT is its driver (the slot variables name the driver folder), one exits with code 3 whatever the driver.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
cat > "$T/game.c" <<'C'
#include <windows.h>
#include <d3d11.h>
#include <string.h>
int main(void) {
    if (GetTickCount() == 1) D3D11CreateDevice(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);   /* keeps the d3d11 import, never runs */
    int always = strstr(GetCommandLineA(), "Always") != NULL;
    for (char *e = GetEnvironmentStringsA(); *e; e += strlen(e) + 1) if (strstr(e, "/drivers/dxmt/")) return 3;   /* "crashes" on DXMT */
    return always ? 3 : 0;
}
C
ct --newbottle F >/dev/null 2>&1; [[ -d "$(tprefix F)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix F)/drive_c/Program Files"
for g in Picky Always Pinned; do mkdir -p "$PF/$g"; x86_64-w64-mingw32-gcc -O2 -s "$T/game.c" -o "$PF/$g/$g.exe" -ld3d11 || fail "could not build $g"; done
opts() { cat "$(tprefix F)/options/$1.exe.env" 2>/dev/null; }
[[ -n "$(ct --status 2>&1 | grep -o 'd3dmetal: [0-9]')" ]] || print "  note: D3DMetal isn't installed in the test home, so DXVK is the next driver"

out=$(ct --launch F "$PF/Picky/Picky.exe" --wait 60 2>&1); rc=$?
[[ "$out" == *"Picky crashed within 30 s with dxmt (exit 3); trying "* ]] || fail "no fallback after the crash: $(print -r -- "$out" | grep -E 'crash|exit|launch:' | tail -4)"
(( rc == 0 )) || fail "the retry with the next driver did not exit 0 (status $rc): $(print -r -- "$out" | grep -E 'launch:|crash' | tail -3)"
next=$(print -r -- "$out" | sed -n 's/.*trying \([a-z0-9]*\) once.*/\1/p' | head -1)
[[ "$(opts Picky)" == *"# driver fallback: dxmt@"*"crashed; using $next"* && "$(opts Picky)" == *"DRIVERS=$next"* ]] || fail "the working driver was not remembered: $(opts Picky)"
print -r -- "ok: Picky crashed on dxmt, was retried once with $next and exited 0; remembered in its Options: $(opts Picky | grep -E 'fallback|DRIVERS' | tr '\n' ' ')"
grep -q "before driver switch: Picky → $next (driver fallback)" "$TS"/bottles/.auto-F-*/.snapshot-reason || fail "no snapshot before the driver switch"
print "ok: a snapshot was taken before the switch"
out=$(ct --launch F "$PF/Picky/Picky.exe" --wait 60 2>&1); rc=$?
(( rc == 0 )) && [[ "$out" != *"crashed within 30 s"* ]] || fail "the remembered driver was not used next time (status $rc)"
print "ok: next launch used $next straight away (exit 0, no crash)"
rep=$(ct --highball-report F "$PF/Picky/Picky.exe" 2>&1 | grep -m1 '^\*\*Driver fallback:\*\*')
[[ "$rep" == "**Driver fallback:** dxmt@"*"crashed; using $next" ]] || fail "the compat report doesn't name the fallback: '$rep'"
print -r -- "ok: the prefilled compat report says: $rep"

out=$(ct --launch F "$PF/Always/Always.exe" --wait 60 2>&1); rc=$?
[[ "$out" == *"Always crashed within 30 s with dxmt (exit 3); trying "* && "$out" == *"crashed with "*" too; it is back to the automatic driver choice."* ]] || fail "Always: $(print -r -- "$out" | grep -E 'crash|launch:' | tail -4)"
(( rc == 3 )) || fail "Always: status $rc, expected the program's 3"
[[ "$(opts Always)" != *"DRIVERS="* ]] || fail "Always kept a driver that crashed: $(opts Always)"
print "ok: Always crashed on dxmt and on the retry (one retry only, status 3); its Options are back to automatic"

print 'DRIVERS=dxmt,d9vk,cnc_ddraw' > "$(tprefix F)/options/Pinned.exe.env"
out=$(ct --launch F "$PF/Pinned/Pinned.exe" --wait 60 2>&1); rc=$?
[[ "$out" == *"ASK: Try Pinned with "*"It crashed right away with dxmt, the driver set in its Options."*"→ Cancel"* ]] || fail "Pinned: no question: $(print -r -- "$out" | grep -E 'ASK|crash|launch:' | tail -3)"
[[ "$(opts Pinned)" == "DRIVERS=dxmt,d9vk,cnc_ddraw" ]] || fail "the user's own driver choice was changed: $(opts Pinned)"
print -r -- "ok: $(print -r -- "$out" | grep -o 'ASK: .*' | head -1); the Options stayed as the user set them"
tw_check || fail "your real data changed"
print "PASS driver_fallback"
