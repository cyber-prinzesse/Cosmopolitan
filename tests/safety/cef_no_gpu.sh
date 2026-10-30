#!/bin/zsh
# CEF hosts under Wine: Chromium's window stays black unless --disable-gpu --disable-gpu-compositing are passed (verified 2026-10-29 with
# 3DMark Demo). Detection is PE import of libcef.dll + that DLL beside the exe. Stand-ins: a stub libcef.dll, a host that imports it and
# writes GetCommandLineW to a file, a control with no libcef import, and CEF_GPU=1 as opt-out.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle C >/dev/null 2>&1; [[ -d "$(tprefix C)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix C)/drive_c/Program Files"
mkdir -p "$PF/CefHost" "$PF/PlainHost"

printf 'LIBRARY libcef.dll\nEXPORTS\ncef_version_info\n' > "$T/libcef.def"
cat > "$T/libcef.c" <<'C'
__declspec(dllexport) int cef_version_info(void) { return 49; }
C
cat > "$T/host.c" <<'C'
#include <windows.h>
#include <stdio.h>
__declspec(dllimport) int cef_version_info(void);
int main(void) {
    if (GetTickCount() == 1) cef_version_info();   /* keeps the import; never runs */
    FILE *f = fopen("C:\\cef-cmdline.txt", "w");
    if (f) { fwprintf(f, L"%s\n", GetCommandLineW()); fclose(f); }
    return 0;
}
C
cat > "$T/plain.c" <<'C'
#include <windows.h>
#include <stdio.h>
int main(void) {
    FILE *f = fopen("C:\\plain-cmdline.txt", "w");
    if (f) { fwprintf(f, L"%s\n", GetCommandLineW()); fclose(f); }
    return 0;
}
C
x86_64-w64-mingw32-gcc -O2 -s -shared "$T/libcef.c" "$T/libcef.def" -o "$PF/CefHost/libcef.dll" || fail "could not build stub libcef.dll"
x86_64-w64-mingw32-dlltool -d "$T/libcef.def" -l "$T/libcef.a" || fail "dlltool libcef"
x86_64-w64-mingw32-gcc -O2 -s "$T/host.c" -o "$PF/CefHost/CefHost.exe" -L"$T" -lcef || fail "could not build CefHost"
x86_64-w64-mingw32-gcc -O2 -s "$T/plain.c" -o "$PF/PlainHost/PlainHost.exe" || fail "could not build PlainHost"
CMD="$(tprefix C)/drive_c/cef-cmdline.txt"; PLAIN="$(tprefix C)/drive_c/plain-cmdline.txt"
opts() { cat "$(tprefix C)/options/$1.exe.env" 2>/dev/null; }

# Launch check names the CEF path.
c=$(ct --check C "$PF/CefHost/CefHost.exe" 2>&1)
[[ "$c" == *"embedded browser window: drawn without the GPU"* ]] || fail "launch check missing CEF note: $c"
print -r -- "ok: launch check: embedded browser window: drawn without the GPU"

# Default: CEF host gets the Chromium switches.
rm -f "$CMD"
tlaunch C "$PF/CefHost/CefHost.exe" 60
[[ $LAUNCH_CODE == 0 && -f "$CMD" ]] || fail "CefHost did not write its command line (exit $LAUNCH_CODE)"
grep -q -- '--disable-gpu' "$CMD" && grep -q -- '--disable-gpu-compositing' "$CMD" || fail "missing CEF GPU switches: $(cat "$CMD")"
print -r -- "ok: CefHost command line has --disable-gpu --disable-gpu-compositing ($LAUNCH_TOOK)"

# CEF_GPU=1: leave the GPU path alone.
print 'CEF_GPU=1' > "$(tprefix C)/options/CefHost.exe.env"
rm -f "$CMD"
tlaunch C "$PF/CefHost/CefHost.exe" 60
[[ $LAUNCH_CODE == 0 && -f "$CMD" ]] || fail "CefHost with CEF_GPU=1 did not run (exit $LAUNCH_CODE)"
grep -q -- '--disable-gpu' "$CMD" && fail "CEF_GPU=1 still got --disable-gpu: $(cat "$CMD")"
print -r -- "ok: CEF_GPU=1 leaves the GPU path alone"
rm -f "$(tprefix C)/options/CefHost.exe.env"

# No libcef import: no extra switches.
c=$(ct --check C "$PF/PlainHost/PlainHost.exe" 2>&1)
[[ "$c" != *"embedded browser window"* ]] || fail "PlainHost must not be a CEF host: $c"
rm -f "$PLAIN"
tlaunch C "$PF/PlainHost/PlainHost.exe" 60
[[ $LAUNCH_CODE == 0 && -f "$PLAIN" ]] || fail "PlainHost did not write its command line (exit $LAUNCH_CODE)"
grep -q -- '--disable-gpu' "$PLAIN" && fail "PlainHost got CEF switches: $(cat "$PLAIN")"
print -r -- "ok: a stand-in without libcef.dll gets no CEF GPU switches"

tw_check || fail "your real data changed"
print "PASS cef_no_gpu"
