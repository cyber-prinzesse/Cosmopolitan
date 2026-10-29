#!/bin/zsh
# Runtime Direct3D 12 detection (mapc-engine GraphicsProbe ideas): games that load d3d12.dll at run time. Stand-ins with no d3d12
# import — one embeds D3D12CreateDevice, one ships d3d12/d3d12core.dll. Also CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal when D3DMetal is used.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle D >/dev/null 2>&1; [[ -d "$(tprefix D)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix D)/drive_c/Program Files"

# Exe with D3D12CreateDevice string, no d3d12.dll import.
mkdir -p "$PF/String DX12"
cat > "$T/str.c" <<'C'
int main(void) {
  static const char entry[] = "D3D12CreateDevice";   /* runtime cue; not an import */
  return entry[0] == 0;
}
C
x86_64-w64-mingw32-gcc -O0 -s "$T/str.c" -o "$PF/String DX12/String DX12.exe" || fail "could not build String DX12"

# Exe with Agility SDK folder beside it, no string / no import.
mkdir -p "$PF/Agility DX12/d3d12"
cat > "$T/plain.c" <<'C'
int main(void) { return 0; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/plain.c" -o "$PF/Agility DX12/Agility DX12.exe" || fail "could not build Agility DX12"
# Minimal PE stub as d3d12core.dll (name + folder matter, not contents).
x86_64-w64-mingw32-gcc -O2 -s -shared "$T/plain.c" -o "$PF/Agility DX12/d3d12/d3d12core.dll" || fail "could not build d3d12core.dll"

# Control: plain exe, no cues.
mkdir -p "$PF/No DX12"
x86_64-w64-mingw32-gcc -O2 -s "$T/plain.c" -o "$PF/No DX12/No DX12.exe" || fail "could not build No DX12"

check() { ct --check D "$PF/$1/$1.exe" 2>&1; }

c=$(check "String DX12")
[[ "$c" == *"Direct3D 12"* ]] || fail "String DX12 should be Direct3D 12: $c"
print -r -- "ok: exe with D3D12CreateDevice string (no d3d12 import): Direct3D 12"

c=$(check "Agility DX12")
[[ "$c" == *"Direct3D 12"* ]] || fail "Agility DX12 should be Direct3D 12: $c"
print -r -- "ok: exe with d3d12/d3d12core.dll beside it: Direct3D 12"

c=$(check "No DX12")
[[ "$c" != *"Direct3D 12"* ]] || fail "No DX12 must not be Direct3D 12: $c"
print -r -- "ok: plain exe without cues is not Direct3D 12"

# CX_ACTIVE_GRAPHICS_BACKEND when the bottle runs D3DMetal (skip if D3DMetal isn't in the test home).
if [[ -d "$TS/engines/renderer/d3dmetal" ]] || [[ -d "$REAL_SUPPORT/engines/renderer/d3dmetal" ]]; then
  # Force d3dmetal into the bottle's driver set for --print-env.
  print 'DRIVERS=d3dmetal,d9vk,cnc_ddraw' >> "$(tprefix D)/cosmopolitan.env"
  # License may be required for driverUsable; accept if the test build has the flag.
  ct --accept-d3dmetal >/dev/null 2>&1 || true
  env=$(ct --print-env 2>&1)
  [[ "$env" == *"CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal"* ]] || fail "missing CX_ACTIVE_GRAPHICS_BACKEND with D3DMetal: $(print -r -- "$env" | grep -E 'CX_|D3DM' | head -5)"
  print "ok: CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal when D3DMetal is the driver set"
  # User override wins.
  print 'CX_ACTIVE_GRAPHICS_BACKEND=custom' >> "$(tprefix D)/cosmopolitan.env"
  env=$(ct --print-env 2>&1)
  [[ "$env" == *"CX_ACTIVE_GRAPHICS_BACKEND=custom"* ]] || fail "user CX_ACTIVE_GRAPHICS_BACKEND was overwritten"
  print "ok: a bottle-set CX_ACTIVE_GRAPHICS_BACKEND is left alone"
else
  print "note: D3DMetal not in the test home; skipped CX_ACTIVE_GRAPHICS_BACKEND checks"
fi

tw_check || fail "your real data changed"
print "PASS dx12_probe"
