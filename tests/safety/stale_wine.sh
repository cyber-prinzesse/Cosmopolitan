#!/bin/zsh
# Leftover Wine processes of an earlier session (2026-10-31: a winedevice.exe from before a forced restart kept the DualSense
# open exclusively, so the next session saw the pad "connected" with no input). Cosmopolitan ends a bottle's Wine processes
# that are older than the bottle's wineserver (or older than the minimum age when no server runs), at launch and when a pad
# connects; it never ends a process whose executable is not an engine loader, a process of the running session, or another
# bottle's process. Also: XInput DLLs missing from system32 are put back from the engine.
# Stand-ins: an idle native binary run as "C:\windows\system32\winedevice.exe" from the bottle's windows folder. Headless.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
setopt no_bgnice

ct --newbottle B >/dev/null 2>&1; [[ -d "$(tprefix B)/drive_c" ]] || fail "throwaway bottle B not created"
ct --newbottle C >/dev/null 2>&1; [[ -d "$(tprefix C)/drive_c" ]] || fail "throwaway bottle C not created"
E="$TS/engines/$ENGINE/wswine.bundle"
clang -O2 -o "$T/idle" -xc - <<'X' || fail "build idle stand-in"
#include <unistd.h>
int main(void) { for (;;) pause(); }
X
cp "$T/idle" "$E/bin/cosmo-test-loader"; cp "$T/idle" "$T/not-an-engine"
WB="$(tprefix B)/drive_c/windows"; WC="$(tprefix C)/drive_c/windows"
standin() {   # standin <exe> <cwd> → pid (argv0 = the Windows command, as Wine sets it)
  ( cd "$2" && ARGV0='C:\windows\system32\winedevice.exe' exec "$1" ) >/dev/null 2>&1 &
  print $!; }
alive() { kill -0 $1 2>/dev/null; }

# 1. No wineserver: old engine process = stale; old non-engine process and other bottle's process stay; young one stays.
old=$(standin "$E/bin/cosmo-test-loader" "$WB"); other=$(standin "$T/not-an-engine" "$WB"); otherbottle=$(standin "$E/bin/cosmo-test-loader" "$WC")
sleep 4
young=$(standin "$E/bin/cosmo-test-loader" "$WB"); sleep 0.5
out=$(COSMO_TEST_STALE_MIN_AGE=3 ct --stale-wine B 2>&1)
sleep 0.5
alive $old && fail "leftover engine process $old not ended: $out"
alive $other || fail "non-engine process $other was ended"
alive $otherbottle || fail "other bottle's process $otherbottle was ended"
alive $young || fail "young process $young (a starting session) was ended"
[[ "$out" == *"Ended 1 Wine process"* ]] || fail "no log line: $out"
print -r -- "ok: no wineserver → only the old engine process of this bottle ended (non-engine, other bottle, young one kept)"
kill $other $young 2>/dev/null

# 2. A running session: processes older than its wineserver are leftovers, newer ones belong to it.
before=$(standin "$E/bin/cosmo-test-loader" "$WB"); sleep 2
twineserver B -p >/dev/null 2>&1; sleep 2
after=$(standin "$E/bin/cosmo-test-loader" "$WB"); sleep 2
out=$(COSMO_TEST_STALE_MIN_AGE=3 ct --stale-wine B 2>&1)
sleep 0.5
alive $before && fail "process $before from before the wineserver not ended: $out"
alive $after || fail "process $after of the running session was ended: $out"
twineserver B -k 2>/dev/null
print -r -- "ok: with a wineserver → older process ended, the session's own process kept, the server untouched"
kill $after $otherbottle 2>/dev/null

# 3. XInput DLLs lost from system32 come back from the engine; present ones are not replaced.
S32="$(tprefix B)/drive_c/windows/system32"
[[ -f "$S32/xinput1_3.dll" ]] || fail "fresh bottle has no xinput1_3.dll to start from"
mv "$S32/xinput1_3.dll" "$T/xinput1_3.saved"; print 'keep' > "$T/marker"; cp "$T/marker" "$S32/xinput1_4.dll.keep"
h4=$(shasum "$S32/xinput1_4.dll" | cut -d' ' -f1)
out=$(ct --restore-xinput B 2>&1)
[[ -f "$S32/xinput1_3.dll" ]] || fail "xinput1_3.dll not restored: $out"
cmp -s "$S32/xinput1_3.dll" "$E/lib/wine/x86_64-windows/xinput1_3.dll" || fail "restored xinput1_3.dll is not the engine's"
[[ "$(shasum "$S32/xinput1_4.dll" | cut -d' ' -f1)" == "$h4" ]] || fail "present xinput1_4.dll was replaced"
[[ "$out" == *"system32/xinput1_3.dll"* ]] || fail "no log line: $out"
print -r -- "ok: missing system32/xinput1_3.dll restored from the engine; present DLLs untouched"

rm -f "$E/bin/cosmo-test-loader"
tw_check || fail "your real data changed"
print "PASS stale_wine"
