#!/bin/zsh
# Item 28: the pre-flight scan (rules in C++, cosmo_preflight). Stand-ins in a throwaway bottle: an exe whose engine DLL beside it imports
# Direct3D 11 (the exe imports none); 64- and 32-bit programs that import the Visual C++ 2015–2022 runtime (the matching runtime is
# installed first); a .NET program recognised by its CLR header (Cosmopolitan's own probe). Read through the launch check (--check).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle P >/dev/null 2>&1; [[ -d "$(tprefix P)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix P)/drive_c/Program Files"; mkdir -p "$PF/Engine Game" "$PF/VC Game" "$PF/VC Game 32" "$PF/Managed"
cat > "$T/engine.c" <<'C'
#include <d3d11.h>
__declspec(dllexport) int engine_start(void) { return D3D11CreateDevice(0, 0, 0, 0, 0, 0, 0, 0, 0, 0) == 0; }
C
cat > "$T/game.c" <<'C'
__declspec(dllimport) int engine_start(void);
int main(void) { return engine_start(); }
C
x86_64-w64-mingw32-gcc -O2 -s -shared "$T/engine.c" -o "$PF/Engine Game/engine.dll" -ld3d11 -Wl,--out-implib,"$T/libengine.a" \
  && x86_64-w64-mingw32-gcc -O2 -s "$T/game.c" -o "$PF/Engine Game/Engine Game.exe" -L"$T" -lengine || fail "could not build Engine Game"
printf 'LIBRARY vcruntime140.dll\nEXPORTS\n__vcrt_InitializeCriticalSectionEx\n' > "$T/vcr.def"
cat > "$T/vc.c" <<'C'
int __vcrt_InitializeCriticalSectionEx(void *, unsigned, unsigned);
int main(int c, char **v) { return c > 5 ? __vcrt_InitializeCriticalSectionEx(0, 0, 0) : 0; }
C
for a in x86_64:"VC Game" i686:"VC Game 32"; do
  x86_64-w64-mingw32-dlltool >/dev/null 2>&1; ${a%%:*}-w64-mingw32-dlltool -d "$T/vcr.def" -l "$T/libvcr-${a%%:*}.a" \
    && ${a%%:*}-w64-mingw32-gcc -O2 -s "$T/vc.c" -o "$PF/${a#*:}/${a#*:}.exe" -L"$T" -lvcr-${a%%:*} || fail "could not build ${a#*:}"
done
cp "$TESTENV_REPO/Resources/netprobe.exe" "$PF/Managed/Managed.exe"
check() { ct --check P "$PF/$1/$1.exe" 2>&1 | grep -m1 "^Launch check"; }

c=$(check "Engine Game")
[[ "$c" == *"the DLLs beside it use d3d11.dll"* && "$c" == *"64-bit Direct3D 11"* ]] || fail "Engine Game: $c"
print -r -- "ok: Engine Game (the exe imports only engine.dll): $c"
c=$(check "VC Game"); [[ "$c" == *"installs Microsoft Visual C++ v14 Redistributable (x64) from Microsoft first"* ]] || fail "VC Game: $c"
print -r -- "ok: VC Game (64-bit, imports vcruntime140.dll): $c"
c=$(check "VC Game 32"); [[ "$c" == *"installs Microsoft Visual C++ v14 Redistributable (x86) from Microsoft first"* ]] || fail "VC Game 32: $c"
print -r -- "ok: VC Game 32 (32-bit, imports vcruntime140.dll): $c"
# Not when the bottle's copy is already Microsoft's (a non-Wine DLL stands in for it) or the game ships its own (Wine's stand-in doesn't count).
cp "$PF/Engine Game/engine.dll" "$(tprefix P)/drive_c/windows/system32/vcruntime140.dll"; cp "$PF/Engine Game/engine.dll" "$PF/VC Game 32/vcruntime140.dll"
c=$(check "VC Game"); [[ "$c" != *"Visual C++"* ]] || fail "VC Game with Microsoft's vcruntime140.dll in system32: $c"
c=$(check "VC Game 32"); [[ "$c" != *"Visual C++"* ]] || fail "VC Game 32 shipping its own vcruntime140.dll: $c"
print "ok: no Visual C++ install when the bottle's copy is Microsoft's (64-bit) or the game ships the DLL (32-bit)"
c=$(check "Managed"); [[ "$c" == *".NET app"* ]] || fail "Managed: $c"
print -r -- "ok: Managed (.NET, CLR header): $c"
tw_check || fail "your real data changed"
print "PASS preflight"
