#!/bin/zsh
# Steam hosts every game's CreateProcess: a driver-fallback DRIVERS= pin on steam.exe must be cleared so DX12 games keep D3DMetal.
# Also: driverFallback must not rewrite steam.exe Options (exit 42 already skips; other early Steam exits must too).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot

ct --newbottle H >/dev/null 2>&1; [[ -d "$(tprefix H)/drive_c" ]] || fail "throwaway bottle not created"
ST="$(tprefix H)/drive_c/Program Files (x86)/Steam"
mkdir -p "$ST" "$(tprefix H)/options"
# Minimal steam.exe stand-in (exits 0 immediately — enough for Options heal on launch)
cat > "$T/steam.c" <<'C'
#include <windows.h>
int main(void) { return 0; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/steam.c" -o "$ST/steam.exe" || fail "could not build steam stand-in"

# Leftover pin from an older Cosmopolitan (real bottle had this after d3dmetal "crashed" on Steam).
print -r -- $'# driver fallback: d3dmetal@2026-10-25 crashed; using dxvk\nDRIVERS=dxvk,cnc_ddraw\n' > "$(tprefix H)/options/steam.exe.env"

out=$(ct --launch H "$ST/steam.exe" --wait 30 2>&1); rc=$?
(( rc == 0 )) || fail "steam stand-in exit $rc: $(print -r -- "$out" | tail -5)"
opts=$(cat "$(tprefix H)/options/steam.exe.env" 2>/dev/null)
[[ "$opts" != *"DRIVERS="* ]] || fail "steam.exe still has DRIVERS pin after launch: $opts"
[[ "$opts" != *"# driver fallback:"* ]] || fail "steam.exe still has fallback mark after launch: $opts"
[[ "$out" == *"removed a driver-fallback pin"* ]] || fail "no heal log line: $(print -r -- "$out" | grep -i steam | tail -5)"
print "ok: launching steam.exe clears a leftover driver-fallback DXVK pin"

# Pin must not come back from driverFallback if Steam exits non-zero quickly (not exit 42).
print -r -- $'# driver fallback: d3dmetal@2026-10-25 crashed; using dxvk\nDRIVERS=dxvk,cnc_ddraw\n' > "$(tprefix H)/options/steam.exe.env"
# Rebuild stand-in that exits 3 within 30 s
cat > "$T/steam.c" <<'C'
#include <windows.h>
int main(void) { return 3; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/steam.c" -o "$ST/steam.exe" || fail "could not rebuild crashing steam"
# Clear pin first via heal, then crash — Options must stay without a new fallback pin
print -r -- '' > "$(tprefix H)/options/steam.exe.env"
out=$(ct --launch H "$ST/steam.exe" --wait 30 2>&1); rc=$?
(( rc == 3 )) || fail "expected exit 3, got $rc: $(print -r -- "$out" | tail -8)"
opts=$(cat "$(tprefix H)/options/steam.exe.env" 2>/dev/null)
[[ "$opts" != *"DRIVERS="* ]] || fail "driverFallback pinned steam.exe after crash: $opts"
[[ "$out" != *"crashed within 30 s"* || "$out" != *"trying"* ]] || fail "driverFallback ran on steam.exe: $(print -r -- "$out" | grep crash | tail -3)"
print "ok: steam.exe early crash does not get a driver-fallback pin"

tw_check || fail "your real data changed"
print "PASS steam_host_drivers"
