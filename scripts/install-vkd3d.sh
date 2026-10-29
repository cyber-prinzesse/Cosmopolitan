#!/bin/zsh
# Installs the vkd3d driver folder (the Direct3D 12 fallback when D3DMetal crashes) from a vkd3d-proton build:
#   scripts/install-vkd3d.sh <vkd3d-proton build64 folder> [support folder, default ~/Library/Application Support/Cosmopolitan]
# d3d12.dll and d3d12core.dll come from the build (64-bit only: Direct3D 12 games are 64-bit), dxgi.dll from the installed DXVK 3
# (renderer/dxvk3, a Wine builtin build). Wine loads a DLL from a driver folder only when it carries the 17-byte "Wine builtin DLL\0"
# mark at 0x40 (in the DOS stub; otherwise "found in WINEDLLPATH but not a builtin, ignoring" and Wine's own d3d12 runs), so the
# copies get it. The previous folder is kept as vkd3d.old. Runs only on engines that ship KosmicKrisp (Drivers.swift, kosmicKrispICD).
setopt err_exit
build=${1:?usage: install-vkd3d.sh <vkd3d-proton build64 folder> [support folder]}
support=${2:-$HOME/Library/Application Support/Cosmopolitan}
r="$support/engines/renderer"
d12=$(find "$build" -name d3d12.dll -path '*d3d12/*' | head -1); core=$(find "$build" -name d3d12core.dll | head -1)
dxgi="$r/dxvk3/wine/x86_64-windows/dxgi.dll"
[[ -f $d12 && -f $core ]] || { print "no d3d12.dll / d3d12core.dll under $build"; exit 1; }
[[ -f $dxgi ]] || { print "no DXVK 3 dxgi.dll at $dxgi (renderer/dxvk3 is installed by first-run setup)"; exit 1; }
[[ "$(dd if=$dxgi bs=1 skip=64 count=16 2>/dev/null)" == "Wine builtin DLL" ]] || { print "$dxgi is not a Wine builtin build"; exit 1; }
for f in $d12 $core; do
  [[ "$(dd if=$f bs=1 skip=0 count=2 2>/dev/null)" == MZ ]] || { print "$f is not a PE file"; exit 1; }
  file -b $f | grep -q 'x86-64' || { print "$f is not a 64-bit DLL"; exit 1; }
done
ver=$(cd "${build:h}" && git describe --tags --always --dirty 2>/dev/null || print unknown)
new="$r/.vkd3d.new"; rm -rf $new; mkdir -p "$new/wine/x86_64-windows"
cp $d12 $core $dxgi "$new/wine/x86_64-windows/"
for f in d3d12 d3d12core; do
  printf 'Wine builtin DLL\0' | dd of="$new/wine/x86_64-windows/$f.dll" bs=1 seek=64 conv=notrunc 2>/dev/null
done
print "vkd3d-proton $ver + dxgi from $(head -1 "$r/dxvk3/version")" > "$new/version"
print "vkd3d-proton: LGPL-2.1, https://github.com/HansKristian-Work/vkd3d-proton (built from $build)\nDXVK dxgi: zlib, see ../dxvk3/LICENSE" > "$new/LICENSE"
rm -rf "$r/vkd3d.old"; [[ -d "$r/vkd3d" ]] && mv "$r/vkd3d" "$r/vkd3d.old"
mv $new "$r/vkd3d"
print "installed $r/vkd3d: $(cat "$r/vkd3d/version")"
