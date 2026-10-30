#!/bin/zsh
# Item 35: the start-up health check. In a throwaway home: a graphics component file changed (one byte), a bottle without Wine Mono, a
# stored setting of a game that is gone, and too little disk space (simulated). --health finds each; --health-fix puts the component back
# (only after a yes; the changed copy kept as .old), removes the stale setting and reinstalls Wine Mono. Disk space has no automatic fix.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
SK="$TH/Library/Application Support/Sikarugir/Template"; mkdir -p "$SK"   # the pinned template, to put a component back from
cp -cR "$REAL_HOME/Library/Application Support/Sikarugir/Template/Template-1.0.24.app" "$SK/" || fail "no local copy of the pinned template"
ct --newbottle H >/dev/null 2>&1; [[ -d "$(tprefix H)/drive_c" ]] || fail "throwaway bottle not created"
mono() { [[ -d "$(tprefix H)/drive_c/windows/mono" ]]; }; poll 180 mono || fail "Wine Mono never arrived in the new bottle"
health() { ct --health 2>&1 | grep '^health: '; }
h=$(health); [[ "$h" == "health: no problems" ]] || fail "a fresh home already has problems: $h"
# P2 (crossover-oracle-findings.md): an installed Mac without Rosetta (simulated) can't start any game; only onboarding used to check.
r=$(COSMO_TEST_NO_ROSETTA=1 ct --health 2>&1 | grep '^health: rosetta'); [[ -n "$r" ]] || fail "no Rosetta problem reported without Rosetta"
f=$(COSMO_TEST_NO_ROSETTA=1 COSMO_TEST_ANSWER=yes ct --health-fix 2>&1 | grep -E '^ASK: Install Rosetta|installer not started')
[[ "$f" == *"apple.com/legal/sla"* && "$f" == *"installer not started"* ]] || fail "the Rosetta fix didn't ask with Apple's licence first: $f"
print -r -- "ok: without Rosetta: ${r#health: }; its Fix asks first (Apple's licence named) and the test build starts no installer"
print "ok: a fresh home: $h"
f=$(ls "$TS/engines/renderer/dxmt/wine/x86_64-windows/"*.dll | head -1); cp "$f" "$f.x" && mv "$f.x" "$f" && printf 'Z' >> "$f"
rm -rf "$(tprefix H)/drive_c/windows/mono" "$(tprefix H)/.dotnet-verified"
L="$(tprefix H)/options/.registry-ledger.json"; mkdir -p "${L:h}"
print -r -- '[ { "exe" : "GoneGame.exe", "key" : "HKCU\\Software\\Wine\\AppDefaults\\GoneGame.exe", "name" : "Version", "owner" : "launch", "value" : "winxp" } ]' > "$L"
GK='HKCU\Software\Wine\AppDefaults\GoneGame.exe'; twine H reg add "$GK" /v Version /t REG_SZ /d winxp /f >/dev/null 2>&1
twine H reg query "$GK" /v Version 2>/dev/null | grep -q winxp || fail "could not store the gone game's setting"
h=$(COSMO_TEST_FREE_GB=5 ct --health 2>&1 | grep '^health: ')
for k in "graphics dxmt" "dotnet H" "stale H" "disk"; do [[ "$h" == *"health: $k"* ]] || fail "--health missed '$k': $h"; done
print -r -- "ok: found all four:"; print -r -- "$h" | sed 's/^/  /'
out=$(COSMO_TEST_ANSWER=yes ct --health-fix 2>&1)
[[ -d "$TS/engines/renderer/dxmt.old" ]] || fail "the changed component was not kept as dxmt.old"
h=$(health); [[ "$h" == "health: no problems" ]] || fail "problems left after --health-fix: $h ($(print -r -- "$out" | grep -E 'ASK|Graphics|Removed' | head -3))"
print -r -- "ok: after --health-fix (yes to putting the component back): $h; the changed copy is dxmt.old"
[[ "$out" == *"Removed 1 stored setting of removed games."* ]] && ! twine H reg query "$GK" /v Version 2>/dev/null | grep -q winxp || fail "the gone game's setting is still in the registry: $(print -r -- "$out" | grep Removed)"
print -r -- "ok: the gone game's setting (AppDefaults\\GoneGame.exe Version) was deleted from the registry"
print -r -- "  $(print -r -- "$out" | grep -E '^(ASK|Graphics|Removed)' | head -3 | tr '\n' ' ')"
tw_check || fail "your real data changed"
print "PASS health"
