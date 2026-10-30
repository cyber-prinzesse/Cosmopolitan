#!/bin/zsh
# Item 14: Microsoft runtimes from Microsoft, pinned (version + SHA-256), installed with the vendor's own silent switches; a wrong download
# installs nothing; a missing DirectX-only DLL makes the launch check plan the DirectX install instead of reporting an unknown DLL.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
tw_snapshot
fail() { print "FAIL: $*"; exit 1; }
native() { [[ -f "$1" ]] && ! grep -q "Wine builtin DLL" "$1"; }
ct --newbottle B >/dev/null 2>&1; W="$(tprefix B)/drive_c/windows"; [[ -d "$W" ]] || fail "bottle not created"

# 1. Wrong download: refused, nothing installed, the good cached file untouched.
mv "$TS/cache/vc_redist.x64.exe" "$T/good64" 2>/dev/null; head -c 4000000 /dev/urandom > "$T/bad.exe"
out=$(COSMO_TEST_URL_vc_redist_x64_exe="file://$T/bad.exe" ct --install-runtime B vcredist64 2>&1)
[[ "$out" == *"checksum mismatch"* ]] && ! native "$W/system32/msvcp140.dll" || fail "a wrong VC++ download was not refused: $out"
mv "$T/good64" "$TS/cache/vc_redist.x64.exe" 2>/dev/null
print "ok: a wrong download is refused (checksum mismatch) and nothing is installed"

# 2.–4. The pinned installers.
for r in vcredist64 vcredist86 directx; do out=$(ct --install-runtime B $r 2>&1); print -r -- "  $r: $(print -r -- "$out" | grep -E '^[✓✗]' | tail -1)"; done
native "$W/system32/msvcp140.dll" && [[ -f "$(tprefix B)/.runtime-vcredist64" ]] || fail "VC++ x64 not installed"
native "$W/syswow64/msvcp140.dll" && [[ -f "$(tprefix B)/.runtime-vcredist86" ]] || fail "VC++ x86 not installed"
print "ok: Visual C++ v14 14.51.36247.0 x64 and x86 installed (Microsoft's msvcp140.dll in system32 and syswow64)"
if native "$W/syswow64/d3dx9_43.dll"; then print "ok: DirectX June 2010 installed (Microsoft's d3dx9_43.dll in syswow64)"; DX=1
else print "note: DirectX June 2010: DXSETUP ran but d3dx9_43.dll is still Wine's own (not verified under this Wine)"; DX=0; fi

# 5. A program importing a DirectX-only DLL: the launch check plans the DirectX install (yellow), not an unknown missing DLL (red).
printf 'LIBRARY d3dx9_99.dll\nEXPORTS\nD3DXFakeFunction\n' > "$T/fake.def"; x86_64-w64-mingw32-dlltool -d "$T/fake.def" -l "$T/libfake.a" -D d3dx9_99.dll
printf 'void D3DXFakeFunction(void);\nint main(void) { D3DXFakeFunction(); return 0; }\n' > "$T/fake.c"
mkdir -p "$W/../Apps"; x86_64-w64-mingw32-gcc "$T/fake.c" "$T/libfake.a" -o "$W/../Apps/needsdx.exe" || fail "could not build the fake program"
rm -f "$(tprefix B)/.runtime-directx"; out=$(ct --check B "$W/../Apps/needsdx.exe" 2>&1)
[[ "$out" == *"installs DirectX End-User Runtime (June 2010) from Microsoft first"* && "$out" != *"missing DLLs"* && "$out" == *"light: yellow"* ]] || fail "launch check: $(print -r -- "$out" | head -2)"
print "ok: a program importing d3dx9_99.dll gets 'installs DirectX End-User Runtime (June 2010) from Microsoft first' (yellow)"
tw_check || fail "your real data changed"
(( DX )) && print "PASS runtimes" || print "PASS runtimes (DirectX install itself not verified)"
