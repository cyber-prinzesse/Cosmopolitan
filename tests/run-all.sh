#!/bin/zsh
# Runs every suite and records each test's real exit code and duration (no output filter can hide a crash): the native tests (ASan +
# UBSan unit tests, libFuzzer), every safety test, and the isolated stress suite. Full logs are kept; key lines are shown, including any
# ERROR / Abort / AddressSanitizer / Traceback / Killed. Usage: tests/run-all.sh [fuzz seconds, default 60]
setopt pipefail
zmodload zsh/datetime
cd "${0:A:h}"; L="/private/tmp/cosmo-test-logs-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$L"
typeset -a rows; fails=0
run() {   # run NAME COMMAND…
  local name=$1; shift; local t0=$EPOCHREALTIME
  "$@" > "$L/$name.log" 2>&1; local rc=$?
  local took=$(printf '%.0f' $(( EPOCHREALTIME - t0 )))
  rows+=("$(printf '%-22s exit %-4s %5ss' $name $rc $took)"); (( rc )) && (( fails++ ))
  print "== $name: exit $rc after ${took}s"
  grep -E '^(ok|PASS|FAIL|note|tripwire|TRIPWIRE|native tests|decision tests|fuzz)|exited with code|exit [0-9-]+ after|still running after|passed \(|ERROR|Abort|AddressSanitizer|Traceback|Killed|Segmentation|terminating' "$L/$name.log" | sed 's/^/   /'
}
run native            ./native/run.sh ${1:-60}
for t in tripwire_rules first_open_text outlive_app malware_scan launch_wait snapshots gog_signin steam_restart steam_loop repair_scope tripwire_setup repair_lock dotnet_new_bottle driver_copies registry_ledger pins d3dmetal_versions battery_cap power_profile runtimes driver_fallback vkd3d_fallback preflight epic_delayload anticheat save_backups templates pad_connect crash_capture health cleanup_suggestions launchers nightly_test log_start red_launcher community_fixes prefix_update; do
  run $t ./safety/$t.sh
done
run stress            ./stress/run.sh
print; print "Summary (full logs in $L):"; print -l $rows
print "$fails of ${#rows} failed"
(( fails == 0 ))
