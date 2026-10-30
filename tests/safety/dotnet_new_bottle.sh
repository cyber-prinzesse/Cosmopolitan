#!/bin/zsh
# Phase 0 N2: a new bottle gets Wine Mono from WineHQ (pinned SHA-256), and a .NET program's light turns green only after the probe
# program has really run in that bottle. A wrong download is rejected and nothing is installed.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
light() { ct --check "$1" "$2" 2>&1 | grep -o 'light: [a-z]*' | tail -1; }
APP="drive_c/Apps/dotnetapp.exe"; place() { mkdir -p "$(tprefix $1)/drive_c/Apps"; cp "$T/CosmopolitanTest.app/Contents/Resources/netprobe.exe" "$(tprefix $1)/$APP"; }
tw_snapshot

# 1. A wrong file served as the Wine Mono download: rejected, nothing installed, light not green.
mv "$TS/cache/wine-mono-9.4.0-x86.msi" "$T/good.msi" 2>/dev/null; head -c 2000000 /dev/urandom > "$T/bad.msi"
out=$(COSMO_TEST_URL_wine_mono_9_4_0_x86_msi="file://$T/bad.msi" ct --newbottle X 2>&1)
[[ "$out" == *"checksum mismatch"* ]] || fail "a wrong Wine Mono download was not rejected: $(print -r -- "$out" | grep -i mono | tail -2)"
[[ ! -d "$(tprefix X)/drive_c/windows/mono" && ! -f "$TS/cache/wine-mono-9.4.0-x86.msi" ]] || fail "something from the bad download was installed or cached"
place X; l=$(light X "$(tprefix X)/$APP"); [[ "$l" != "light: green" ]] || fail "a .NET program is green in a bottle without a working runtime"
print "ok: bad download rejected (checksum mismatch), nothing installed, .NET program $l"

# 2. A normal new bottle: Wine Mono installed from the verified file, probe ran, marker written.
[[ -f "$T/good.msi" ]] && mv "$T/good.msi" "$TS/cache/wine-mono-9.4.0-x86.msi"
out=$(ct --newbottle N 2>&1)
[[ -d "$(tprefix N)/drive_c/windows/mono" ]] || fail "Wine Mono not installed in the new bottle: $(print -r -- "$out" | tail -3)"
grep -q "^netprobe ok" "$(tprefix N)/.dotnet-verified" 2>/dev/null || fail "probe did not run in the new bottle"
print "ok: new bottle has Wine Mono $(cat "$(tprefix N)/.dotnet-verified" | head -1)"

# 3. Green only with the marker.
place N; l=$(light N "$(tprefix N)/$APP"); [[ "$l" == "light: green" ]] || fail ".NET program not green after a successful probe ($l)"
mv "$(tprefix N)/.dotnet-verified" "$T/marker"; l=$(light N "$(tprefix N)/$APP"); [[ "$l" != "light: green" ]] || fail "green without a probe run"
print "ok: green with the probe marker, $l without it"

# 4. Launching re-probes before starting, then the program runs.
tlaunch N "$(tprefix N)/$APP" || fail "the .NET program did not exit within 120 s ($LAUNCH_LINE)"
grep -q "^netprobe ok" "$(tprefix N)/.dotnet-verified" 2>/dev/null || fail "launch did not re-run the probe first"
[[ "$LAUNCH_CODE" == 0 ]] || fail "the .NET program exited with code $LAUNCH_CODE"
print "ok: the launch re-ran the probe, then the program exited with code 0 after $LAUNCH_TOOK"
tw_check || fail "your real data changed"
print "PASS dotnet_new_bottle"
