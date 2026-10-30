#!/bin/zsh
# Measure Library idle CPU with ~50 stand-in tiles. Prints numbers for the report (not a CI gate).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot

ct --newbottle L >/dev/null 2>&1
PF="$(tprefix L)/drive_c/Program Files"; print 'int main(void){return 0;}' > "$T/g.c"
x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$T/g.exe" || fail "build"
for i in {01..50}; do mkdir -p "$PF/Game$i"; cp "$T/g.exe" "$PF/Game$i/Game$i.exe"; done
# Force a scan so library is filled before the window app starts
ct --status L >/dev/null 2>&1

sandbox-exec -p "$(tw_sandbox_profile)" env CFFIXED_USER_HOME="$TH" HOME="$TH" COSMO_TEST_HOME="$TH" \
  "$T/CosmopolitanTest.app/Contents/MacOS/Cosmopolitan" >/dev/null 2>&1 & app=$!
poll 30 kill -0 $app || fail "app did not start"
sleep 6
sample $app 3 -file "$T/sample.txt" 2>/dev/null || sample $app 3 > "$T/sample.txt" 2>&1
c1=$(ps -p $app -o %cpu= | tr -d ' '); sleep 2; c2=$(ps -p $app -o %cpu= | tr -d ' ')
hits=$(grep -cE 'SwiftUI|NSImage|ViewBody|ImageProvider|TextLayout' "$T/sample.txt" 2>/dev/null || print 0)
print "ui_speed_measure: pid=$app idle_cpu=${c1}% idle_cpu_2s=${c2}% sample_ui_hits=$hits tiles=50"
# Top of sample (excluding binary path noise)
awk '/Call graph:/{p=1} p&&/^[0-9 ]/{print; if(++n>=20) exit}' "$T/sample.txt" 2>/dev/null | head -20

kill $app 2>/dev/null; wait $app 2>/dev/null
tw_check || true
print "PASS ui_speed_measure"
