#!/bin/zsh
# Regression for the C1 incident (a test run created a bottle in the real folder): the test build must refuse to run without a
# throwaway home or with a home inside your real one, and a full --setup run must leave your data untouched. Checksums of your
# bottles folder, log and Steam bottle are compared before and after. The run is also sandboxed, so any attempt to write into your
# real Cosmopolitan folders, log or Sikarugir folder fails loudly instead of happening.
unset COSMO_ENGINE COSMO_ENGINE_DIR   # first-run setup installs the pinned engine, whatever engine a trial run is testing
source "${0:A:h}/../lib/testenv.sh"; TESTENV_NO_ENGINE=1 testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
BIN="$T/CosmopolitanTest.app/Contents/MacOS/Cosmopolitan"

# 1. The guard
out=$(env -u COSMO_TEST_HOME -u CFFIXED_USER_HOME "$BIN" --status 2>&1); rc=$?
[[ $rc == 78 ]] || fail "test build ran without COSMO_TEST_HOME (exit $rc): $out"
out=$(COSMO_TEST_HOME="$REAL_HOME" "$BIN" --status 2>&1); rc=$?
[[ $rc == 78 && "$out" == *"inside your real home"* ]] || fail "test build ran with your real home (exit $rc): $out"
print "ok: the test build refuses to run without a throwaway home, and with your real home"

# 2. A full first-run setup in the throwaway home: no downloads (local engine tarball and template cloned in, minus any D3DMetal).
SK="$TH/Library/Application Support/Sikarugir"; mkdir -p "$SK/Engines" "$SK/Template"
cp -c "$REAL_HOME/Library/Application Support/Sikarugir/Engines/$ENGINE.tar.xz" "$SK/Engines/" || fail "no local engine tarball to seed"
for t in "$REAL_HOME/Library/Application Support/Sikarugir/Template"/Template-*.app(N); do cp -cR "$t" "$SK/Template/"; done
rm -rf "$SK"/Template/*/Contents/SharedSupport/renderer/d3dmetal*   # the clone only; setup never uses it
tw_snapshot
sandbox-exec -p "$(tw_sandbox_profile)" env CFFIXED_USER_HOME="$TH" HOME="$TH" COSMO_TEST_HOME="$TH" "$BIN" --setup > "$T/setup.log" 2>&1; rc=$?
grep -i "deny\|Operation not permitted" "$T/setup.log" | head -3
[[ $rc == 0 ]] || fail "setup failed in the throwaway home (exit $rc): $(tail -3 "$T/setup.log")"
[[ -f "$TS/bottles/Games/drive_c/windows/system32/kernel32.dll" ]] || fail "setup made no first bottle in the throwaway home"
grep -q "^netprobe ok" "$TS/bottles/Games/.dotnet-verified" 2>/dev/null || fail "setup's first bottle has no working .NET (Wine Mono + probe)"
grep -q "Downloading Microsoft runtimes" "$T/setup.log" || fail "setup did not fetch the Microsoft runtimes"
for f in vc_redist.x86.exe:f0bab33a vc_redist.x64.exe:84306899 directx_Jun2010_redist.exe:053f76dc; do
  [[ "$(shasum -a 256 "$TS/cache/${f%%:*}" 2>/dev/null | cut -c1-8)" == "${f##*:}" ]] || fail "setup's cache lacks a verified ${f%%:*}"
done
tw_check sandboxed || fail "your real data changed"
print "PASS tripwire_setup: setup ran entirely in $TH; your data is unchanged"
