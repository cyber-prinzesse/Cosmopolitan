#!/bin/zsh
# Direct3D 12 fallback: a program that crashes within 30 s on D3DMetal is retried once on vkd3d-proton (renderer/vkd3d, KosmicKrisp), and
# that is remembered. Needs an engine that ships KosmicKrisp (Highball's Wine 11; COSMO_ENGINE_DIR, default the Beta's highball-11.0-r29)
# and a vkd3d-proton build (VKD3D_BUILD, default ~/Cosmopolitan-engine-trials/build-vkd3d/vkd3d-proton/build64); skipped without them.
# Stand-in: a 64-bit program importing d3d12 that exits 3 when D3DMetal's folder is in its environment, 4 when vkd3d's is there without
# feature level 12_1, else 0. (VK_DRIVER_FILES never reaches the Windows environment, only the Unix side where the Vulkan loader reads it:
# the KosmicKrisp ICD is checked as a file here; GravityMark D3D12 rendering on KosmicKrisp through this path was checked by hand.) A second check: the Sikarugir engine never offers vkd3d.
: ${COSMO_ENGINE_DIR:="$HOME/Library/Application Support/Cosmopolitan Beta/engines/highball-11.0-r29"}
: ${VKD3D_BUILD:="$HOME/Cosmopolitan-engine-trials/build-vkd3d/vkd3d-proton/build64"}
[[ -f "$COSMO_ENGINE_DIR/engine/lib/wine/x86_64-unix/libvulkan_kosmickrisp.dylib" ]] || { print "SKIP vkd3d_fallback: no KosmicKrisp engine at $COSMO_ENGINE_DIR"; exit 0; }
[[ -d $VKD3D_BUILD ]] || { print "SKIP vkd3d_fallback: no vkd3d-proton build at $VKD3D_BUILD"; exit 0; }
export COSMO_ENGINE=highball-11.0-r29 COSMO_ENGINE_DIR
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
[[ -d "$TS/engines/renderer/d3dmetal/wine" ]] || { print "SKIP vkd3d_fallback: D3DMetal isn't installed, so there is no D3DMetal crash to fall back from"; exit 0; }
"${0:A:h}/../../scripts/install-vkd3d.sh" $VKD3D_BUILD "$TS" >/dev/null || fail "install-vkd3d.sh failed"
for f in d3d12 d3d12core; do [[ "$(dd if="$TS/engines/renderer/vkd3d/wine/x86_64-windows/$f.dll" bs=1 skip=64 count=17 2>/dev/null | xxd -p)" == 57696e65206275696c74696e20444c4c00 ]] || fail "$f.dll lacks Wine's builtin mark"; done
print "ok: install-vkd3d.sh made renderer/vkd3d ($(cat "$TS/engines/renderer/vkd3d/version")), DLLs marked as Wine builtins"
cat > "$T/game.c" <<'C'
#include <windows.h>
#include <d3d12.h>
#include <string.h>
int main(void) {
    if (GetTickCount() == 1) D3D12CreateDevice(0, 0, 0, 0);   /* keeps the d3d12 import, never runs */
    int vk = 0, fl = 0;
    for (char *e = GetEnvironmentStringsA(); *e; e += strlen(e) + 1) {
        if (strstr(e, "/drivers/d3dmetal/")) return 3;   /* "crashes" on D3DMetal */
        if (strstr(e, "/drivers/vkd3d/")) vk = 1;
        if (!strcmp(e, "VKD3D_FEATURE_LEVEL=12_1")) fl = 1;
    }
    return vk && !fl ? 4 : 0;
}
C
ct --newbottle V >/dev/null 2>&1; [[ -d "$(tprefix V)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix V)/drive_c/Program Files"; mkdir -p "$PF/Twelve"
x86_64-w64-mingw32-gcc -O2 -s "$T/game.c" -o "$PF/Twelve/Twelve.exe" -ld3d12 || fail "could not build the stand-in"
opts() { cat "$(tprefix V)/options/Twelve.exe.env" 2>/dev/null; }

out=$(ct --launch V "$PF/Twelve/Twelve.exe" --wait 60 2>&1); rc=$?
[[ "$out" == *"Twelve crashed within 30 s with d3dmetal (exit 3); trying vkd3d once."* ]] || fail "no vkd3d fallback: $(print -r -- "$out" | grep -E 'crash|exit|launch:|driver' | tail -4)"
[[ "$out" == *"vkd3d-proton draws Direct3D 12 without D3DMetal"* ]] || fail "the speed note is missing"
(( rc == 0 )) || fail "the retry on vkd3d did not exit 0 (status $rc; 4 = no feature level 12_1)"
[[ "$(opts)" == *"crashed; using vkd3d"* && "$(opts)" == *"DRIVERS=vkd3d,cnc_ddraw"* ]] || fail "vkd3d was not remembered: $(opts)"
[[ "$(cat "$TS/engines/renderer/vkd3d/KosmicKrisp_icd-highball-11.0-r29.json")" == *'"is_portability_driver": false'* ]] || fail "no KosmicKrisp ICD written"
print -r -- "ok: crashed on d3dmetal, retried on vkd3d with feature level 12_1 and a KosmicKrisp ICD, exit 0; remembered: $(opts | grep -E 'fallback|DRIVERS' | tr '\n' ' ')"
out=$(ct --launch V "$PF/Twelve/Twelve.exe" --wait 60 2>&1); rc=$?
(( rc == 0 )) && [[ "$out" != *"crashed within 30 s"* ]] || fail "the remembered vkd3d was not used next time (status $rc)"
print "ok: next launch used vkd3d straight away"

defaults write "$TESTID" engine WS12WineSikarugir10.0_8; cp -cR "$REAL_SUPPORT/engines/WS12WineSikarugir10.0_8" "$TS/engines/" 2>/dev/null
if [[ -d "$TS/engines/WS12WineSikarugir10.0_8" ]]; then
  : > "$(tprefix V)/options/Twelve.exe.env"
  out=$(ct --launch V "$PF/Twelve/Twelve.exe" --wait 60 2>&1)
  [[ "$out" != *"trying vkd3d"* && "$(opts)" != *vkd3d* ]] || fail "vkd3d was offered on the Sikarugir engine (no KosmicKrisp): $(print -r -- "$out" | grep -E 'crash|trying' | tail -2)"
  print -r -- "ok: on the Sikarugir engine vkd3d is never offered: $(print -r -- "$out" | grep -E 'crashed within' | head -1)"
fi
tw_check || fail "your real data changed"
print "PASS vkd3d_fallback"
