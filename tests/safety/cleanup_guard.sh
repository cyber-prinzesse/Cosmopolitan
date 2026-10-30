#!/bin/zsh
# Guard: _testenv_pids_under_T must select ZERO pids for every bad \$T / pattern, and only a dummy under a
# valid throwaway for a good \$T. No real kills of system processes — run this BEFORE cleanup_orphans.
source "${0:A:h}/../lib/testenv.sh"
fail() { print "FAIL: $*"; exit 1; }

expect_zero() {
  local label=$1
  shift
  local pids
  pids=$(_testenv_pids_under_T "$@" 2>/dev/null) || true
  [[ -z "$pids" ]] || fail "$label: expected 0 pids, got: $pids"
  print "ok: $label → 0 pids"
}

# --- bad inputs (must never match the world) ---
unset T
expect_zero "T unset" ""
expect_zero "T empty" ""
expect_zero "T=/" "/"
expect_zero "T=/private/tmp/cosmotest. (incomplete)" "/private/tmp/cosmotest."
expect_zero "T=/private/tmp/cosmotest.TOOOLONG" "/private/tmp/cosmotest.TOOOLONG"
expect_zero "T with slash trail" "/private/tmp/cosmotest.Ab12Cd/"
# Former sed-escape footgun: empty/wrong escape must not become ^/
expect_zero "T=//" "//"
expect_zero "T=/tmp/cosmotest.Ab12Cd (wrong prefix)" "/tmp/cosmotest.Ab12Cd"

# Pattern builder itself must reject bad T
_testenv_kill_pattern "/" >/dev/null 2>&1 && fail "_testenv_kill_pattern accepted /"
_testenv_kill_pattern "" >/dev/null 2>&1 && fail "_testenv_kill_pattern accepted empty"
print "ok: _testenv_kill_pattern rejects / and empty"

# --- valid T: only the dummy under that folder ---
VT=$(mktemp -d /private/tmp/cosmotest.XXXXXX) || fail "mktemp"
_testenv_t_ok "$VT" || fail "mktemp path not accepted as T: $VT"
print '#include <unistd.h>\nint main(void){for(;;) pause(); return 0;}' > "$VT/dummy.c"
clang -O0 -o "$VT/guard-dummy" "$VT/dummy.c" || fail "build guard-dummy"
"$VT/guard-dummy" &
DPID=$!
sleep 0.3
kill -0 $DPID 2>/dev/null || fail "guard-dummy did not start"
pids=$(_testenv_pids_under_T "$VT" 2>/dev/null) || fail "valid T refused"
print -r -- " $pids " | grep -q " $DPID " || fail "valid T: expected pid $DPID in [$pids]"
# Must not include Dock / Finder / this shell
print -r -- " $pids " | grep -q " $$ " && fail "selected this shell"
for name in Dock Finder; do
  sp=$(pgrep -x "$name" | head -1)
  [[ -n "$sp" ]] && print -r -- " $pids " | grep -q " $sp " && fail "selected $name ($sp)"
done
print "ok: valid T → only throwaway dummy (pid $DPID among: $pids)"

# Tear down dummy ourselves (do not exercise full cleanup kill path here)
kill -TERM $DPID 2>/dev/null
sleep 0.3
kill -KILL $DPID 2>/dev/null
wait $DPID 2>/dev/null
rm -rf "$VT"
print "PASS cleanup_guard"
