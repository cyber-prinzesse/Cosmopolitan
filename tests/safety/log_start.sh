#!/bin/zsh
# Log fix follow-up: the window app begins its fresh log when it starts, not at its first write. An app left idle used to replace the whole
# log at its first click hours later, with everything written since its start (Settings › Controller › Live test did that on 2026-10-23).
# The test build starts as a window app in a throwaway home over a log from a "previous session"; nothing is clicked. The previous log is kept as Cosmopolitan.previous.log.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
L="$TH/Library/Logs/Cosmopolitan.log"; mkdir -p "${L:h}"; print "previous session" > "$L"
sandbox-exec -p "$(tw_sandbox_profile)" env CFFIXED_USER_HOME="$TH" HOME="$TH" COSMO_TEST_HOME="$TH" "$T/CosmopolitanTest.app/Contents/MacOS/Cosmopolitan" >/dev/null 2>&1 & app=$!
trap 'kill $app 2>/dev/null; wait $app 2>/dev/null; testenv_cleanup' EXIT
fresh() { kill -0 $app 2>/dev/null && [[ -f "$L" ]] && ! grep -q "previous session" "$L"; }
poll 20 fresh || fail "${POLL_TOOK} s after the start the log still holds the previous session ($(kill -0 $app 2>/dev/null && print 'app running' || print 'app gone'))"
print "ok: the window app began a fresh log ${POLL_TOOK} s after its start, with nothing clicked"
grep -q "previous session" "$TH/Library/Logs/Cosmopolitan.previous.log" 2>/dev/null || fail "the previous session's log wasn't kept as Cosmopolitan.previous.log"
print "ok: the previous session's log is kept as Cosmopolitan.previous.log"
kill $app; wait $app 2>/dev/null
tw_check || fail "your real data changed"
print "PASS log_start"
