#!/bin/zsh
# The x87sidecar (athei, MIT) speeds up 32-bit x87 code under Rosetta ~10x, but only Wine 11 engines carry its hook (Highball patch 0012).
# So ROSETTA_X87_PATH is set only on a Wine 11 engine AND only when the sidecar is installed. Wine 10 must NEVER get it — it has no hook,
# and its behaviour must be unchanged. (Measured: 32-bit D3D9 6 → 45 fps on r29 with the sidecar; Wine 10 is 31 fps.)
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle G >/dev/null 2>&1
# Wine 10 (this test's default engine): even with the sidecar installed, never set it.
: > "$TS/x87sidecar"   # a stand-in file; the gate checks existence, launchEnv only passes the path to Wine 11's hook
ct --print-env G 2>/dev/null | grep -q ROSETTA_X87_PATH && fail "Wine 10 got ROSETTA_X87_PATH (it has no x87 hook; Wine 10 must be unchanged)"
print "ok: Wine 10 never sets ROSETTA_X87_PATH, even with the sidecar installed"
rm -f "$TS/x87sidecar"
ct --print-env G 2>/dev/null | grep -q ROSETTA_X87_PATH && fail "set with no sidecar installed"
print "ok: not set when the sidecar isn't installed"
tw_check || fail "your real data changed"
# Wine 11 (r29), when present on this Mac: with the sidecar it IS set, to the installed path.
R="$REAL_HOME/Cosmopolitan-engine-trials/highball-11.0-r29"
if [[ -d "$R/wswine.bundle" ]]; then
  testenv_cleanup; COSMO_ENGINE=highball-11.0-r29 COSMO_ENGINE_DIR="$R" testenv_init >/dev/null || exit 1
  : > "$TS/x87sidecar"; ct --newbottle W >/dev/null 2>&1
  r=$(ct --print-env W 2>/dev/null | grep '^ROSETTA_X87_PATH=')
  [[ "$r" == *"/x87sidecar" ]] || fail "Wine 11 with the sidecar did not set ROSETTA_X87_PATH (got: ${r:-nothing})"
  print "ok: Wine 11 (r29) with the sidecar sets it: ${r}"
else
  print "note: highball-11.0-r29 not on this Mac; skipped the Wine 11 set-case"
fi
print "PASS x87_gate"
