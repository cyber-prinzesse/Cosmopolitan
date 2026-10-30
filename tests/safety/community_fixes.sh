#!/bin/zsh
# Community fixes (umu-protonfixes) on a Mac. The Witcher 3 5.0's fix hides Wine (hidewineexports=enable) so the game turns on Streamline,
# ray tracing and frame generation: right with an NVIDIA card on Linux, a crash 1.6 s after start under D3DMetal (2026-10-23). On D3DMetal it
# isn't applied, and is undone once where it was. And a fix winetricks.log already records isn't run again (each run stops Steam).
# Steam layout in a throwaway bottle; the fixes are pre-seeded in <bottle>/fixes (fresh for 7 days), so nothing is downloaded.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle S >/dev/null 2>&1; [[ -d "$(tprefix S)/drive_c" ]] || fail "throwaway bottle not created"
P="$(tprefix S)"; A="$P/drive_c/Program Files (x86)/Steam/steamapps"; W="$A/common/The Witcher 3"; X="$A/common/Fake DX11"
mkdir -p "$W/bin/x64_dx12" "$X" "$P/fixes"
print 'int main(void){return 0;}' > "$T/m.c"
cat > "$T/d12.c" <<'C'
#include <d3d12.h>
__declspec(dllexport) int f(void) { static const GUID g; return D3D12CreateDevice(0, D3D_FEATURE_LEVEL_11_0, &g, 0) == 0; }
C
cat > "$T/d11.c" <<'C'
#include <d3d11.h>
int main(void) { return GetTickCount() == 1 ? D3D11CreateDevice(0, 0, 0, 0, 0, 0, 0, 0, 0, 0) : 0; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/m.c" -o "$P/drive_c/Program Files (x86)/Steam/steam.exe" && x86_64-w64-mingw32-gcc -O2 -s "$T/m.c" -o "$W/REDprelauncher.exe" \
  && x86_64-w64-mingw32-gcc -O2 -s "$T/m.c" -o "$W/bin/x64_dx12/witcher3.exe" && x86_64-w64-mingw32-gcc -O2 -s -shared "$T/d12.c" -o "$W/bin/x64_dx12/GFSDK_SSAO_D3D12.win64.dll" -ld3d12 \
  && x86_64-w64-mingw32-gcc -O2 -s "$T/d11.c" -o "$X/FakeDX11.exe" -ld3d11 || fail "could not build the stand-ins"
print -r -- '{ "executables": [ { "description": "DirectX 12", "executable": { "directoryPath": "bin\\x64_dx12", "fileName": "witcher3.exe" } } ], "fallback": "DirectX 12" }' > "$W/launcher-configuration.json"
for g in "292030 The Witcher 3" "900001 Fake DX11"; do id=${g%% *} n=${g#* }
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"%s"\n}\n' $id "$n" "$n" > "$A/appmanifest_$id.acf"
  print "from protonfixes import util\n\ndef main() -> None:\n    util.protontricks('hidewineexports=enable')" > "$P/fixes/$id.py"; : > "$P/fixes/$id.json"; : > "$P/fixes/$id.highball.json"
done
check() { ct --check S "$1" 2>&1 | grep -m1 '^Launch check'; }

# 1. D3DMetal game (The Witcher 3 layout): the fix isn't planned.
c=$(check "$W/REDprelauncher.exe"); [[ "$c" == *"d3dmetal"* && "$c" != *"hidewineexports=enable"* ]] || fail "D3DMetal game, fix not applied yet: $c"
print "ok: on D3DMetal hidewineexports=enable is not applied (plan: d3dmetal)"
# 2. Applied before (winetricks.log says enable): undone once.
print "hidewineexports=enable" > "$P/winetricks.log"
c=$(check "$W/REDprelauncher.exe"); [[ "$c" == *"fetching hidewineexports=disable via winetricks"* ]] || fail "D3DMetal game, fix applied before: $c"
print "ok: where it was applied, it is undone once (fetching hidewineexports=disable)"
print "hidewineexports=disable" >> "$P/winetricks.log"
c=$(check "$W/REDprelauncher.exe"); [[ "$c" != *"hidewineexports"* ]] || fail "after the undo: $c"
print "ok: once undone, nothing more to do"
# 3. Another driver (a DirectX 11 game): the fix applies, but not a second time.
: > "$P/winetricks.log"; c=$(check "$X/FakeDX11.exe"); [[ "$c" == *"fetching hidewineexports=enable via winetricks"* ]] || fail "DX11 game, first time: $c"
print "hidewineexports=enable" > "$P/winetricks.log"; c=$(check "$X/FakeDX11.exe"); [[ "$c" != *"hidewineexports"* ]] || fail "DX11 game, already applied: $c"
print "ok: on another driver the fix is applied once; when winetricks.log records it, it isn't run again"
tw_check || fail "your real data changed"
print "PASS community_fixes"
