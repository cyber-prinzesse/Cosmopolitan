#!/bin/zsh
# Epic "Won't run" false positive (item 5): the Epic Games Launcher delay-loads libcef.dll — the loader resolves it lazily, from the
# launcher's own folders, and the program starts fine even when it is not where our check looks. The launch check must NOT treat a
# delay-load-only import as a hard "missing DLL" and light the tile red. The normal/delay split is parsed natively (pe_test.cpp); this
# proves the launch check (--check) acts on it, on the shipping engine. Stand-ins in a throwaway bottle: one exe that DELAY-loads a DLL
# that is nowhere in the bottle (must not be red), and a control that imports the SAME DLL normally (must stay red "missing DLLs").
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle E >/dev/null 2>&1; [[ -d "$(tprefix E)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix E)/drive_c/Program Files"; mkdir -p "$PF/Delay Launcher" "$PF/Needs It"
# optcef.dll stands in for Epic's libcef.dll: a DLL name that is no Wine builtin and maps to no runtime or winetricks verb, so a HARD
# import of it, missing from the bottle, is a red "missing DLLs". Same source and symbol for both exes — only the import KIND differs.
printf 'LIBRARY optcef.dll\nEXPORTS\nopt_entry\n' > "$T/optcef.def"
cat > "$T/app.c" <<'C'
__declspec(dllimport) int opt_entry(void);
int main(int c, char **v) { return c > 5 ? opt_entry() : 0; }   /* never actually called; just keeps the import in the table */
C
x86_64-w64-mingw32-dlltool -d "$T/optcef.def" -y "$T/liboptdelay.a"  || fail "dlltool delay lib"   # -y: optcef.dll becomes delay-load
x86_64-w64-mingw32-dlltool -d "$T/optcef.def" -l "$T/liboptnormal.a" || fail "dlltool normal lib"  # -l: optcef.dll becomes a hard import
x86_64-w64-mingw32-gcc -O2 -s "$T/app.c" -o "$PF/Delay Launcher/Delay Launcher.exe" -L"$T" -loptdelay  || fail "could not build the delay exe"
x86_64-w64-mingw32-gcc -O2 -s "$T/app.c" -o "$PF/Needs It/Needs It.exe"               -L"$T" -loptnormal || fail "could not build the control exe"
check() { ct --check E "$PF/$1/$1.exe" 2>&1; }

# Control: a normal import of optcef.dll, nowhere in the bottle → red, and named as a missing DLL. (Proves the check still fires at all.)
c=$(check "Needs It")
[[ "$c" == *"missing DLLs: optcef.dll"* && "$c" == *"light: red"* ]] || fail "control (hard import of optcef.dll) should be red with a missing DLL: $c"
print -r -- "ok: a normal import of a missing optcef.dll is red (missing DLLs: optcef.dll)"
# The fix: delay-loaded optcef.dll is optional — never a missing DLL, never red.
c=$(check "Delay Launcher")
[[ "$c" != *"optcef.dll"* ]]  || fail "delay-loaded optcef.dll must not be reported missing: $c"
[[ "$c" != *"light: red"* ]]  || fail "a delay-loaded optional DLL must not make the tile red: $c"
print -r -- "ok: a launcher that delay-loads optcef.dll is not red and optcef.dll is not flagged missing"
tw_check || fail "your real data changed"
print "PASS epic_delayload"
