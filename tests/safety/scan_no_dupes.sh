#!/bin/zsh
# Library scan never duplicates. Regressions from a clone of the user's Steam bottle (2026-10-30):
# - Steam tile exe = REDprelauncher with launcher-configuration.json → must keep Witcher (store-backed, never a "helper").
# - Battle.net Launcher + Battle.net.exe + Battle.net.NNNNN/bdk/BlizzardError → one Battle.net tile, no helpers.
# - Futuremark/SystemInfo/FMSIScan.exe → never a tile.
# Also: Unreal bootstrap+shipping, symlink, two bottles, idempotent --find, hidden ids.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot

ct --newbottle A >/dev/null 2>&1; ct --newbottle B >/dev/null 2>&1
[[ -d "$(tprefix A)/drive_c" && -d "$(tprefix B)/drive_c" ]] || fail "bottles not created"
print 'int main(void){return 0;}' > "$T/g.c"
x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$T/g.exe" || fail "build stub"

# --- Exact Witcher layout: Steam entry is REDprelauncher; game in launcher-configuration.json ---
SA="$(tprefix A)/drive_c/Program Files (x86)/Steam"
W="$SA/steamapps/common/The Witcher 3"; mkdir -p "$W/bin/x64_dx12" "$SA/steamapps"
printf '"AppState"\n{\n\t"appid"\t\t"292030"\n\t"name"\t\t"The Witcher 3: Wild Hunt — Remastered"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"The Witcher 3"\n}\n' > "$SA/steamapps/appmanifest_292030.acf"
cp "$T/g.exe" "$W/REDprelauncher.exe"
cp "$T/g.exe" "$W/bin/x64_dx12/witcher3.exe"
print '{"fallback":"DirectX 12","executables":[{"description":"DirectX 12","executable":{"directoryPath":"bin\\\\x64_dx12","fileName":"witcher3.exe"}}]}' > "$W/launcher-configuration.json"

# --- Battle.net: Launcher + client + versioned bdk error reporter (must not become tiles / second Battle.net) ---
BN="$(tprefix A)/drive_c/Program Files (x86)/Battle.net"
mkdir -p "$BN/Battle.net.17952/bdk"
cp "$T/g.exe" "$BN/Battle.net Launcher.exe"
cp "$T/g.exe" "$BN/Battle.net.exe"
cp "$T/g.exe" "$BN/Battle.net.17952/GameSessionMonitor.exe"
cp "$T/g.exe" "$BN/Battle.net.17952/bdk/BlizzardError.exe"

# --- Futuremark system-info scanner ---
mkdir -p "$(tprefix A)/drive_c/Program Files (x86)/Futuremark/SystemInfo"
cp "$T/g.exe" "$(tprefix A)/drive_c/Program Files (x86)/Futuremark/SystemInfo/FMSIScan.exe"

# --- Unreal bootstrap + shipping ---
UE="$(tprefix A)/drive_c/Program Files/FakeUnreal"; mkdir -p "$UE/Binaries/Win64" "$UE/Engine"
cp "$T/g.exe" "$UE/FakeUnreal.exe"
cp "$T/g.exe" "$UE/Binaries/Win64/FakeUnreal-Win64-Shipping.exe"
print -r -- "$UE/FakeUnreal.exe" > "$(tprefix A)/cosmopolitan.apps"
print -r -- "$UE/Binaries/Win64/FakeUnreal-Win64-Shipping.exe" >> "$(tprefix A)/cosmopolitan.apps"

# --- Solo + symlink ---
mkdir -p "$(tprefix A)/drive_c/Program Files/Solo" "$(tprefix A)/drive_c/Games"
cp "$T/g.exe" "$(tprefix A)/drive_c/Program Files/Solo/Solo.exe"
ln -s "../Program Files/Solo" "$(tprefix A)/drive_c/Games/SoloLink"
print -r -- "$(tprefix A)/drive_c/Games/SoloLink/Solo.exe" >> "$(tprefix A)/cosmopolitan.apps"

# --- Bottle B: same Steam Witcher ---
SB="$(tprefix B)/drive_c/Program Files (x86)/Steam"
WB="$SB/steamapps/common/The Witcher 3"; mkdir -p "$WB/bin/x64_dx12" "$SB/steamapps"
printf '"AppState"\n{\n\t"appid"\t\t"292030"\n\t"name"\t\t"The Witcher 3: Wild Hunt — Remastered"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"The Witcher 3"\n}\n' > "$SB/steamapps/appmanifest_292030.acf"
cp "$T/g.exe" "$WB/REDprelauncher.exe"
cp "$T/g.exe" "$WB/bin/x64_dx12/witcher3.exe"
print '{"fallback":"DirectX 12","executables":[{"description":"DirectX 12","executable":{"directoryPath":"bin\\\\x64_dx12","fileName":"witcher3.exe"}}]}' > "$WB/launcher-configuration.json"

status1=$(ct --status A 2>&1)
print -r -- "$status1" | grep -q '^library: ' || fail "no library line: $(print -r -- "$status1" | tail -8)"
libline=$(print -r -- "$status1" | grep '^library: ')
witcher=$(print -r -- "$status1" | grep -c 'steam:292030' || true)
[[ "$witcher" == 1 ]] || fail "Witcher identity count=$witcher (want 1) — REDprelauncher store tile must stay: $status1"
print -r -- "$status1" | grep -q 'The Witcher 3: Wild Hunt' || fail "store display name missing: $status1"
# Prefer witcher3 over REDprelauncher when both exist (steam walk digs to depth 4; score cache is under options/).
[[ -f "$(tprefix A)/options/.score-witcher3.exe" ]] || fail "expected options/.score-witcher3.exe (tile should be the game exe, not only REDprelauncher)"
# Battle.net: one battlenet: identity (Launcher + Battle.net.exe share it)
bnid=$(print -r -- "$status1" | grep -c 'battlenet:' || true)
[[ "$bnid" == 1 ]] || fail "Battle.net identity count=$bnid (want 1): $(print -r -- "$status1" | grep -i battle)"
print -r -- "$status1" | grep -qi 'BlizzardError\|GameSessionMonitor\|FMSIScan' && fail "helper became a tile: $status1"
print -r -- "$status1" | grep -qi 'FakeUnreal' || fail "Unreal game missing"
print -r -- "ok: $libline; Witcher×1, Battle.net×1, no helpers"

# --find must not add BlizzardError / FMSIScan / second Battle.net; second find adds 0
out1=$(ct --find A 2>&1)
print -r -- "$out1" | grep -qi 'BlizzardError\|FMSIScan\|GameSessionMonitor' && fail "find listed a helper: $out1"
out2=$(ct --find A 2>&1)
print -r -- "$out2" | grep -q 'Find apps: 0 new' || fail "second find not idempotent: $out2"
status2=$(ct --status A 2>&1)
[[ "$(print -r -- "$status2" | grep -c 'battlenet:')" == 1 ]] || fail "Battle.net duplicated after find"
[[ "$(print -r -- "$status2" | grep -c 'steam:292030')" == 1 ]] || fail "Witcher lost/duplicated after find"
print "ok: --find added no helpers; second --find added 0"

# Score cache must not appear beside a user-picked folder's exes
EXT="$T/external/SomeGame"; mkdir -p "$EXT"; cp "$T/g.exe" "$EXT/SomeGame.exe"
ct --find A "$EXT" >/dev/null 2>&1
setopt NULL_GLOB
ls "$EXT"/.cosmo-score-*(N) 2>/dev/null | grep -q . && fail "wrote .cosmo-score-* beside external exe: $(ls -A "$EXT")"
unsetopt NULL_GLOB
print "ok: no .cosmo-score-* beside external-folder exes"

# Hide Witcher; rescan keeps it hidden
print 'steam:292030' > "$TS/cosmopolitan.hidden"
status3=$(ct --status A 2>&1)
print -r -- "$status3" | grep -q 'steam:292030' && fail "hidden Witcher still listed"
print "ok: hidden steam:292030 stays hidden"

tw_check || fail "your real data changed"
print "PASS scan_no_dupes"
