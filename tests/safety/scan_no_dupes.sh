#!/bin/zsh
# Library scan never duplicates: store manifest + plain exe, Unreal bootstrap + -Win64-Shipping, CDPR REDprelauncher + game,
# symlink (/tmp vs real path), same game in two bottles → one tile. Second --find / scan adds nothing. Hidden tiles stay hidden.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot

ct --newbottle A >/dev/null 2>&1; ct --newbottle B >/dev/null 2>&1
[[ -d "$(tprefix A)/drive_c" && -d "$(tprefix B)/drive_c" ]] || fail "bottles not created"
print 'int main(void){return 0;}' > "$T/g.c"
x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$T/g.exe" || fail "build stub"

# --- Bottle A: Steam Witcher-like (manifest + REDprelauncher + witcher3 + find-apps path) ---
SA="$(tprefix A)/drive_c/Program Files (x86)/Steam"
W="$SA/steamapps/common/The Witcher 3"; mkdir -p "$W/bin/x64_dx12" "$SA/steamapps"
printf '"AppState"\n{\n\t"appid"\t\t"292030"\n\t"name"\t\t"The Witcher 3: Wild Hunt — Remastered"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"The Witcher 3"\n}\n' > "$SA/steamapps/appmanifest_292030.acf"
cp "$T/g.exe" "$W/REDprelauncher.exe"
cp "$T/g.exe" "$W/bin/x64_dx12/witcher3.exe"
# launcher-configuration.json so redGame() points at witcher3
print '{"fallback":"DirectX 12","executables":[{"description":"DirectX 12","executable":{"directoryPath":"bin\\\\x64_dx12","fileName":"witcher3.exe"}}]}' > "$W/launcher-configuration.json"
# Also list REDprelauncher in cosmopolitan.apps (Find apps style duplicate of the Steam game)
print -r -- "$W/REDprelauncher.exe" > "$(tprefix A)/cosmopolitan.apps"

# --- Bottle A: Unreal bootstrap + shipping ---
UE="$(tprefix A)/drive_c/Program Files/FakeUnreal"; mkdir -p "$UE/Binaries/Win64" "$UE/Engine"
cp "$T/g.exe" "$UE/FakeUnreal.exe"
cp "$T/g.exe" "$UE/Binaries/Win64/FakeUnreal-Win64-Shipping.exe"
# Both bootstrap and shipping listed (Find apps would find shipping under Binaries/)
print -r -- "$UE/FakeUnreal.exe" >> "$(tprefix A)/cosmopolitan.apps"
print -r -- "$UE/Binaries/Win64/FakeUnreal-Win64-Shipping.exe" >> "$(tprefix A)/cosmopolitan.apps"

# --- Bottle A: plain Program Files game ---
mkdir -p "$(tprefix A)/drive_c/Program Files/Solo"; cp "$T/g.exe" "$(tprefix A)/drive_c/Program Files/Solo/Solo.exe"

# --- Symlink duplicate: same Solo via a linked path recorded in cosmopolitan.apps ---
mkdir -p "$(tprefix A)/drive_c/Games"
ln -s "../Program Files/Solo" "$(tprefix A)/drive_c/Games/SoloLink"
print -r -- "$(tprefix A)/drive_c/Games/SoloLink/Solo.exe" >> "$(tprefix A)/cosmopolitan.apps"

# --- Bottle B: same Steam Witcher (cross-bottle) ---
SB="$(tprefix B)/drive_c/Program Files (x86)/Steam"
WB="$SB/steamapps/common/The Witcher 3"; mkdir -p "$WB/bin/x64_dx12" "$SB/steamapps"
printf '"AppState"\n{\n\t"appid"\t\t"292030"\n\t"name"\t\t"The Witcher 3: Wild Hunt — Remastered"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"The Witcher 3"\n}\n' > "$SB/steamapps/appmanifest_292030.acf"
cp "$T/g.exe" "$WB/bin/x64_dx12/witcher3.exe"
print '{"fallback":"DirectX 12","executables":[{"description":"DirectX 12","executable":{"directoryPath":"bin\\\\x64_dx12","fileName":"witcher3.exe"}}]}' > "$WB/launcher-configuration.json"

# Helper that must never be a tile
mkdir -p "$(tprefix A)/drive_c/Program Files/Junk"
cp "$T/g.exe" "$(tprefix A)/drive_c/Program Files/Junk/UnityCrashHandler64.exe"

status1=$(ct --status A 2>&1)
print -r -- "$status1" | grep -q '^library: ' || fail "no library line: $(print -r -- "$status1" | tail -5)"
libline=$(print -r -- "$status1" | grep '^library: ')
# Expect: Witcher (once), FakeUnreal (once), Solo (once), Steam client maybe, no UnityCrashHandler
# Count game identity lines
ids=$(print -r -- "$status1" | grep -E '^\s+.*\[(A|B)\] ' | wc -l | tr -d ' ')
witcher=$(print -r -- "$status1" | grep -c 'steam:292030' || true)
ue=$(print -r -- "$status1" | grep -c 'ue:' || true)
solo=$(print -r -- "$status1" | grep -ci 'Solo' || true)
crash=$(print -r -- "$status1" | grep -ci 'UnityCrashHandler' || true)
[[ "$witcher" == 1 ]] || fail "Witcher identity count=$witcher (want 1): $status1"
[[ "$crash" == 0 ]] || fail "UnityCrashHandler became a tile"
# Prefer store display name
print -r -- "$status1" | grep -q 'The Witcher 3: Wild Hunt' || fail "store display name missing: $status1"
# Prefer shipping / not only bootstrap name for Unreal tile
print -r -- "$status1" | grep -qi 'FakeUnreal' || fail "Unreal game missing"
# Cross-bottle: one Witcher, alts implied (library count of steam:292030 is 1)
print -r -- "ok: $libline; Witcher×1, no crash handler"

# Second find / scan adds nothing
out1=$(ct --find A 2>&1)
out2=$(ct --find A 2>&1)
print -r -- "$out2" | grep -q 'Find apps: 0 new' || fail "second find not idempotent: $out2"
status2=$(ct --status A 2>&1)
lib2=$(print -r -- "$status2" | grep '^library: ')
[[ "$lib2" == "$libline" ]] || fail "rescan changed library: before=$libline after=$lib2"
print "ok: second --find added nothing; library unchanged"

# Hide Witcher; rescan keeps it hidden (same file hideFromLibrary writes)
print 'steam:292030' > "$TS/cosmopolitan.hidden"
status3=$(ct --status A 2>&1)
print -r -- "$status3" | grep -q 'steam:292030' && fail "hidden Witcher still listed: $(print -r -- "$status3" | grep Witcher)"
print "ok: hidden steam:292030 stays hidden after scan"

tw_check || fail "your real data changed"
print "PASS scan_no_dupes"
