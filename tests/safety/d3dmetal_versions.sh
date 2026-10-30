#!/bin/zsh
# Issue A: D3DMetal's version and features are read from the framework; installing an older or less capable one changes nothing without a
# yes and lists what would be lost; the installed one is always kept as a backup. Fake toolkits only (no Apple files in tests).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
tw_snapshot
fail() { print "FAIL: $*"; exit 1; }
R="$TS/engines/renderer"; rm -rf "$R/d3dmetal" "$TS/d3dmetal-license.json"   # throwaway copies only; start without D3DMetal
mkkit() {   # mkkit DIR VERSION TITLE FEATURE…
  local d="$1" v="$2" t="$3"; shift 3; local fw="$d/redist/lib/external/D3DMetal.framework"
  mkdir -p "$fw/Versions/A/Resources" "$d/redist/lib/wine/x86_64-windows"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $v" "$fw/Versions/A/Resources/Info.plist" >/dev/null
  print -r -- "fake binary $*" > "$fw/D3DMetal"; print fake > "$d/redist/lib/wine/x86_64-windows/d3d12.dll"
  print -r -- '{\rtf1 Fake license}' > "$d/License.rtf"; print -r -- "{\\rtf1 $t README}" > "$d/Read Me.rtf"
}
mkkit "$T/kit4" 4.0b3 "Evaluation environment for Windows games 4.0 beta 3" D3DM_SUPPORT_DXR D3DM_ENABLE_METALFX D3DM_MTL4 D3DM_MAX_FPS
mkkit "$T/kit3" 3.0 "Evaluation environment for Windows games 3.0" D3DM_SUPPORT_DXR D3DM_ENABLE_METALFX
st() { ct --status 2>&1 | grep '^d3dmetal:'; }

ct --install-d3dmetal "$T/kit4" >/dev/null 2>&1
[[ "$(st)" == "d3dmetal: 4.0 beta 3 from Evaluation environment for Windows games 4.0 beta 3; features: D3DM_ENABLE_METALFX D3DM_MAX_FPS D3DM_MTL4 D3DM_SUPPORT_DXR"* ]] || fail "version/features not read: $(st)"
print -r -- "ok: $(st)"
before=$(ct --tree-hash "$R/d3dmetal" 2>/dev/null | grep -o '^[0-9a-f]*')
out=$(ct --install-d3dmetal "$T/kit3" 2>&1)
[[ "$out" == *"This replaces D3DMetal 4.0 beta 3 with 3.0. You lose the 60 fps battery cap for Direct3D 12, the Metal 4 backend."*"Nothing changed"* ]] || fail "downgrade without --yes did not warn: $out"
[[ "$(st)" == "d3dmetal: 4.0 beta 3"* ]] || fail "downgrade happened without --yes"
print -r -- "ok: without --yes: $(print -r -- "$out" | grep -o 'This replaces.*backup\.')"
ct --install-d3dmetal "$T/kit3" --yes >/dev/null 2>&1
[[ "$(st)" == "d3dmetal: 3.0 from Evaluation environment for Windows games 3.0"* ]] || fail "approved downgrade did not install 3.0: $(st)"
[[ "$(ct --tree-hash "$R/d3dmetal@4.0b3" 2>/dev/null | grep -o '^[0-9a-f]*')" == "$before" ]] || fail "4.0b3 was not kept byte-identical as d3dmetal@4.0b3"
[[ ! -f "$TS/d3dmetal-license.json" ]] || fail "license acceptance survived a version change"
print "ok: with --yes 3.0 is installed; 4.0b3 kept byte-identical at d3dmetal@4.0b3; license acceptance withdrawn"
out=$(ct --install-d3dmetal "$T/kit4" 2>&1)
[[ "$(st)" == "d3dmetal: 4.0 beta 3"* && -d "$R/d3dmetal@3.0" && "$out" != *"You lose"* ]] || fail "upgrade to 4.0b3 asked or lost the 3.0 backup: $out"
print "ok: upgrading needs no yes and keeps 3.0 at d3dmetal@3.0"
tw_check || fail "your real data changed"
print "PASS d3dmetal_versions"
