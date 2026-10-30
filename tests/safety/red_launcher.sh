#!/bin/zsh
# A game whose tile is a launcher (The Witcher 3, 2026-10-23): the Library said "Ready", but CD Projekt's REDprelauncher starts
# REDlauncher, whose Qt window can't get an OpenGL context here; skipping it, the engine's built-in rewrite turns
# bin\x64_dx12\witcher3.exe into bin\x64\witcher3.exe, a DirectX 11 build the DirectX 12-only game no longer has.
# Stand-ins, same layout: launcher-configuration.json (DirectX 12 only); REDprelauncher.exe starts the configured game only with
# --launcher-skip (exit 4 if that start fails, like the real "Failed to launch game!"), else fails like REDlauncher (exit 3);
# bin\x64_dx12\witcher3.exe records how it was started; a DLL beside it imports d3d12.dll, like the real game's.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle W >/dev/null 2>&1; [[ -d "$(tprefix W)/drive_c" ]] || fail "throwaway bottle not created"
D="$(tprefix W)/drive_c/Program Files/The Witcher 3"; mkdir -p "$D/bin/x64_dx12"; R="$(tprefix W)/drive_c/w3.txt"
cat > "$T/pre.c" <<'C'
#include <windows.h>
#include <string.h>
#include <stdio.h>
int main(void) {
    if (!strstr(GetCommandLineA(), "--launcher-skip")) return 3;   /* REDlauncher: "Failed to create OpenGL context" */
    char dir[MAX_PATH], cmd[2 * MAX_PATH]; GetModuleFileNameA(0, dir, MAX_PATH); *strrchr(dir, '\\') = 0;
    snprintf(cmd, sizeof cmd, "\"%s\\bin\\x64_dx12\\witcher3.exe\"  -dx12", dir);   /* what the real prelauncher runs */
    STARTUPINFOA si = { sizeof si }; PROCESS_INFORMATION pi;
    if (!CreateProcessA(0, cmd, 0, 0, FALSE, 0, 0, 0, &si, &pi)) return 4;
    WaitForSingleObject(pi.hProcess, INFINITE); DWORD c = 1; GetExitCodeProcess(pi.hProcess, &c); return (int)c;
}
C
cat > "$T/game.c" <<'C'
#include <windows.h>
#include <stdio.h>
int main(void) { char p[MAX_PATH]; GetModuleFileNameA(0, p, MAX_PATH); FILE *f = fopen("C:\\w3.txt", "w"); if (f) { fprintf(f, "%s | %s", GetCommandLineA(), p); fclose(f); } return 0; }
C
cat > "$T/ssao.c" <<'C'
#include <d3d12.h>
__declspec(dllexport) int ssao(void) { static const GUID g; return D3D12CreateDevice(0, D3D_FEATURE_LEVEL_11_0, &g, 0) == 0; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/pre.c" -o "$D/REDprelauncher.exe" && x86_64-w64-mingw32-gcc -O2 -s "$T/game.c" -o "$D/bin/x64_dx12/witcher3.exe" \
  && x86_64-w64-mingw32-gcc -O2 -s -shared "$T/ssao.c" -o "$D/bin/x64_dx12/GFSDK_SSAO_D3D12.win64.dll" -ld3d12 || fail "could not build the stand-ins"
print -r -- '{ "revision": 3, "executables": [ { "description": "DirectX 12", "executable": { "directoryPath": "bin\\x64_dx12", "fileName": "witcher3.exe" } } ], "gameId": "witcher3", "platform": "steam", "fallback": "DirectX 12" }' > "$D/launcher-configuration.json"
K="$TS/engines/$ENGINE/wswine.bundle/lib/wine/x86_64-windows/kernelbase.dll"
rewrites=$(python3 -I -c 'import sys; print(1 if "\\bin\\x64_dx12\\witcher3.exe".encode("utf-16-le") in open(sys.argv[1], "rb").read() else 0)' "$K")
pre='C:\Program Files\The Witcher 3\REDprelauncher.exe'

# 0. The situation: without --launcher-skip the launcher fails (3); with it, the engine's rewrite to bin\x64 makes the start fail (4).
twine W "$pre" >/dev/null 2>&1; rc=$?; (( rc == 3 )) || fail "the stand-in prelauncher without --launcher-skip: exit $rc, expected 3"
twine W "$pre" --launcher-skip -dx12 >/dev/null 2>&1; rc=$?
if (( rewrites )); then (( rc == 4 )) && [[ ! -f "$R" ]] || fail "with the engine's rewrite and no bin\x64 the start should fail: exit $rc"
  print -r -- "ok: the situation reproduced: without --launcher-skip exit 3 (REDlauncher), with it exit 4 (the engine starts bin\x64\witcher3.exe, which isn't there)"
else print -r -- "note: this engine doesn't rewrite bin\x64_dx12\witcher3.exe (exit $rc); no link is needed"; rm -f "$R"; fi

# 1. The launch check looks at the game, not the prelauncher: Direct3D 12 from the DLL beside it, started without REDlauncher.
c=$(ct --check W "$D/REDprelauncher.exe" 2>&1 | grep -m1 '^Launch check')
[[ "$c" == *"Direct3D 12"* && "$c" == *"starts witcher3.exe without REDlauncher"* ]] || fail "launch check: $c"
print -r -- "ok: $(print -r -- "$c" | sed -e 's/; not installed through a store — run only if you trust where it came from//' -e 's/; AVX scan pending//')"

# 2. Play through the app: the game itself starts, with -dx12 (through bin\x64 when the engine rewrites), after a snapshot.
tlaunch W "$D/REDprelauncher.exe" 60; [[ $LAUNCH_CODE == 0 && -f "$R" && "$(cat "$R")" == *"-dx12"* ]] || fail "Play: exit $LAUNCH_CODE, game record: $(cat "$R" 2>/dev/null)"
if (( rewrites )); then
  [[ "$(readlink "$D/bin/x64")" == x64_dx12 && "$(cat "$R")" == *'\bin\x64\witcher3.exe'* ]] || fail "no bin\x64 link or not started through it: $(ls -la "$D/bin" | tail -2)"
  ct --snapshots W 2>&1 | grep -q "before linking bin.x64 to x64_dx12" || fail "no snapshot before the link: $(ct --snapshots W 2>&1 | tail -3)"
  print -r -- "ok: Play started the game ($(cut -d'|' -f1 "$R")) through bin\x64 → x64_dx12, made after a snapshot; exit 0 in $LAUNCH_TOOK"
else print -r -- "ok: Play started the game ($(cut -d'|' -f1 "$R")); exit 0 in $LAUNCH_TOOK"; fi

# 3. Again: the link is there, no second snapshot, the game starts.
n1=$(ct --snapshots W 2>&1 | grep -c "before linking"); rm -f "$R"
tlaunch W "$D/REDprelauncher.exe" 60; [[ $LAUNCH_CODE == 0 && -f "$R" && $(ct --snapshots W 2>&1 | grep -c "before linking") == $n1 ]] || fail "second Play: exit $LAUNCH_CODE"
print "ok: a second Play starts it again without another link or snapshot"
tw_check || fail "your real data changed"
print "PASS red_launcher"
