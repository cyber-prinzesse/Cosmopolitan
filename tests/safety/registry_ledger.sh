#!/bin/zsh
# Phase 0 N3: registry values Cosmopolitan writes are recorded and removed when the setting is gone. Pre-ledger leftovers with our signature
# are adopted and swept (the .NET test then reports Windows NT instead of Windows 98); a value the user changed is left alone; bottle
# settings such as Steam's tweaks are never swept.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
AD='HKCU\Software\Wine\AppDefaults'
rq() { twine L reg query "$1" /v "$2" 2>/dev/null | tr -d '\r' | awk -v n="$2" '$1==n {print $3; f=1} END {if (!f) print "<none>"}'; }
os() { tail -1 "$(tprefix L)/drive_c/StressTest/results.txt" | grep -o 'os=.*'; }
tw_snapshot
ct --newbottle L >/dev/null 2>&1; [[ -d "$(tprefix L)/drive_c" ]] || fail "bottle not created"
stress_build L || fail "could not build the stress test programs into the throwaway bottle"
DOT="$(tprefix L)/drive_c/StressTest/stress-dotnet.exe"; D11="$(tprefix L)/drive_c/StressTest/stress-d3d11-64.exe"

# 1. Leftovers from before the ledger, exactly as in your Steam bottle: win98 + virtual desktop + Retina off for stress-dotnet.exe.
twine L reg add "$AD\\stress-dotnet.exe" /v Version /t REG_SZ /d win98 /f >/dev/null
twine L reg add "$AD\\stress-dotnet.exe\\Explorer" /v Desktop /t REG_SZ /d Cosmopolitan /f >/dev/null
twine L reg add "$AD\\stress-dotnet.exe\\Mac Driver" /v RetinaMode /t REG_SZ /d n /f >/dev/null
# a bottle setting that must survive any sweep (Steam's tweak), recorded the way the app records it
twine L reg add "$AD\\steam.exe\\DllOverrides" /v xinput1_4 /t REG_SZ /d '' /f >/dev/null
twineserver L -w   # flush to user.reg
mkdir -p "$(tprefix L)/options"; print -r -- '[{"exe":"steam.exe","key":"HKCU\\Software\\Wine\\AppDefaults\\steam.exe\\DllOverrides","name":"xinput1_4","owner":"bottle","value":""}]' > "$(tprefix L)/options/.registry-ledger.json"
tlaunch L "$DOT" || fail "the .NET test did not exit within 120 s"; print "  stress-dotnet exited with code $LAUNCH_CODE after $LAUNCH_TOOK"; before=$(os)
[[ "$before" == *" 4.10."* ]] || fail "stale win98 key (Windows 4.10) not in effect before the sweep ($before)"
out=$(ct --sweep-registry L 2>&1); print -r -- "$out" | grep -A4 "removed"
[[ "$(rq "$AD\\stress-dotnet.exe" Version)" == "<none>" && "$(rq "$AD\\stress-dotnet.exe\\Explorer" Desktop)" == "<none>" ]] || fail "stale keys still there after the sweep"
[[ "$(rq "$AD\\steam.exe\\DllOverrides" xinput1_4)" != "<none>" ]] || fail "the sweep removed a bottle setting (Steam's tweak)"
tlaunch L "$DOT" || fail "the .NET test did not exit within 120 s"; print "  stress-dotnet exited with code $LAUNCH_CODE after $LAUNCH_TOOK"; after=$(os)
[[ "$after" =~ ' (6|[1-9][0-9])\.' ]] || fail ".NET test still on an old Windows version after the sweep ($after)"
print "ok: stale win98 keys swept; the .NET test went from '$before' to '$after'; Steam's tweak kept"

# 2. A setting turned off is removed at the next launch (MOUSE_CAPTURE option).
print 'MOUSE_CAPTURE=1' > "$(tprefix L)/options/stress-d3d11-64.exe.env"; tlaunch L "$D11" || fail "stress-d3d11-64 did not exit within 120 s"
[[ "$(rq "$AD\\stress-d3d11-64.exe\\DirectInput" MouseWarpOverride)" == force ]] || fail "MOUSE_CAPTURE did not write its key"
rm "$(tprefix L)/options/stress-d3d11-64.exe.env"; out=$(ct --launch L "$D11" --wait 120 2>&1)
[[ "$(rq "$AD\\stress-d3d11-64.exe\\DirectInput" MouseWarpOverride)" == "<none>" ]] || fail "turned-off MOUSE_CAPTURE left its key"
print -r -- "ok: turning MOUSE_CAPTURE off removed its key ($(print -r -- "$out" | grep -o "Removed registry settings.*" | head -1))"

# 3. A value the user changed after we wrote it is left alone.
print 'MOUSE_CAPTURE=1' > "$(tprefix L)/options/stress-d3d11-64.exe.env"; tlaunch L "$D11" || fail "stress-d3d11-64 did not exit within 120 s"
twine L reg add "$AD\\stress-d3d11-64.exe\\DirectInput" /v MouseWarpOverride /t REG_SZ /d enable /f >/dev/null
rm "$(tprefix L)/options/stress-d3d11-64.exe.env"; tlaunch L "$D11" || fail "stress-d3d11-64 did not exit within 120 s"
[[ "$(rq "$AD\\stress-d3d11-64.exe\\DirectInput" MouseWarpOverride)" == enable ]] || fail "a user-changed value was removed"
print "ok: a value changed by the user stays"
tw_check || fail "your real data changed"
print "PASS registry_ledger"
