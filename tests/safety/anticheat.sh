#!/bin/zsh
# Item 29: anti-cheat check. A local AreWeAntiCheatYet list (stand-in for the one fetched at runtime) and a stand-in Steam library: a game
# AreWeAntiCheatYet lists as Denied (EAC), one as Supported (EAC), one with kernel anti-cheat (Vanguard, Broken), and one it doesn't know
# that ships BattlEye files. The decision engine (cosmo_anticheat) turns these into red / yellow badges, read through the launch check.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
cat > "$T/games.json" <<'J'
[{"name":"Denied Arena","storeIds":{"steam":"111"},"status":"Denied","anticheats":["Easy Anti-Cheat"]},
 {"name":"Supported Raid","storeIds":{"steam":"222"},"status":"Supported","anticheats":["Easy Anti-Cheat"]},
 {"name":"Kernel Shooter","storeIds":{"steam":"333"},"status":"Broken","anticheats":["Vanguard"]}]
J
out=$(COSMO_TEST_URL_awacy="file://$T/games.json" ct --awacy-refresh 2>&1 | grep '^AreWeAntiCheatYet'); [[ "$out" == "AreWeAntiCheatYet list: 3 games." ]] || fail "refresh: $out"
print -r -- "ok: fetched at runtime into the cache: $out"
ct --newbottle A >/dev/null 2>&1; [[ -d "$(tprefix A)/drive_c" ]] || fail "throwaway bottle not created"
ST="$(tprefix A)/drive_c/Program Files (x86)/Steam/steamapps"; mkdir -p "$ST/common"
print 'int main(void){return 0;}' > "$T/g.c"; x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$T/g.exe" || fail "could not build the stand-in"
for g in 111:DeniedArena 222:SupportedRaid 333:KernelShooter 444:QuietSiege; do
  id=${g%%:*} n=${g#*:}; mkdir -p "$ST/common/$n"; cp "$T/g.exe" "$ST/common/$n/$n.exe"
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"%s"\n}\n' $id $n $n > "$ST/appmanifest_$id.acf"
done
mkdir -p "$ST/common/QuietSiege/BattlEye"; print x > "$ST/common/QuietSiege/BattlEye/BEService.exe"
check() { ct --check A "$ST/common/$1/$1.exe" 2>&1 | grep -E "^Launch check|^drivers override" | tr '\n' ' '; }
c=$(check DeniedArena); [[ "$c" == *"the developer blocks Wine/Proton (AreWeAntiCheatYet: Denied)"* && "$c" == *"light: red"* ]] || fail "Denied: $c"
print -r -- "ok: Denied Arena → red: $(print -r -- "$c" | grep -o 'Anti-cheat ([^)]*): [^;]*')"
c=$(check SupportedRaid); [[ "$c" == *"Online won't work (Easy Anti-Cheat); offline/single-player usually fine (AreWeAntiCheatYet: Supported on Linux)"* && "$c" == *"light: yellow"* ]] || fail "Supported: $c"
print -r -- "ok: Supported Raid → yellow: $(print -r -- "$c" | grep -o "Online won't work[^;]*;[^;]*")"
c=$(check KernelShooter); [[ "$c" == *"Kernel anti-cheat (Vanguard): will not run"* && "$c" == *"light: red"* ]] || fail "Kernel: $c"
print -r -- "ok: Kernel Shooter → red: $(print -r -- "$c" | grep -o 'Kernel anti-cheat ([^)]*): [^;]*')"
c=$(check QuietSiege); [[ "$c" == *"Online won't work (BattlEye)"* && "$c" == *"light: yellow"* ]] || fail "BattlEye files: $c"
print -r -- "ok: Quiet Siege (not on the list, BattlEye files) → yellow: $(print -r -- "$c" | grep -o "Online won't work ([^)]*)")"
tw_check || fail "your real data changed"
print "PASS anticheat"
