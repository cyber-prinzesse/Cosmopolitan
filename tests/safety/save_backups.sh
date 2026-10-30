#!/bin/zsh
# Item 30: save backups from the Ludusavi manifest. A small manifest in the real format (stand-in for the one fetched at runtime) knows the
# stand-in Steam game "Test Quest" (app 555): saves in AppData/Roaming/TestQuest/save*.dat and in <base>/Saves, plus a Linux-only path
# that must be ignored. Its saves are backed up on request, before Repair, before a driver switch and before a game update; the newest 5
# are kept; files the manifest doesn't name are not copied.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
cat > "$T/manifest.yaml" <<'Y'
# stand-in, same shape as ludusavi-manifest's data/manifest.yaml
Other Game:
  files:
    <winDocuments>/Other:
      tags:
        - save
  steam:
    id: 999
Test Quest:
  files:
    <winAppData>/TestQuest/save*.dat:
      tags:
        - save
    "<base>/Saves":
      tags:
        - save
    <home>/.config/testquest:
      when:
        - os: linux
      tags:
        - config
  installDir:
    TestQuest: {}
  steam:
    id: 555
Y
out=$(COSMO_TEST_URL_ludusavi="file://$T/manifest.yaml" ct --ludusavi-refresh 2>&1 | grep '^Ludusavi'); [[ "$out" == "Ludusavi manifest: 2 games." ]] || fail "refresh: $out"
print -r -- "ok: fetched at runtime into the cache: $out"
ct --newbottle Q >/dev/null 2>&1; [[ -d "$(tprefix Q)/drive_c" ]] || fail "throwaway bottle not created"
C="$(tprefix Q)/drive_c"; ST="$C/Program Files (x86)/Steam/steamapps"; mkdir -p "$ST/common/TestQuest/Saves"
print 'int main(void){return 0;}' > "$T/g.c"; x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$ST/common/TestQuest/TestQuest.exe" || fail "could not build the stand-in"
manifest() { printf '"AppState"\n{\n\t"appid"\t\t"555"\n\t"name"\t\t"Test Quest"\n\t"StateFlags"\t\t"%s"\n\t"installdir"\t\t"TestQuest"\n\t"TargetBuildID"\t\t"%s"\n}\n' $1 $2 > "$ST/appmanifest_555.acf"; }
manifest 4 100
U=$(ls "$C/users" | grep -v Public | head -1); mkdir -p "$C/users/$U/AppData/Roaming/TestQuest" "$C/users/$U/.config/testquest"
print one > "$C/users/$U/AppData/Roaming/TestQuest/save1.dat"; print two > "$C/users/$U/AppData/Roaming/TestQuest/save2.dat"
print no > "$C/users/$U/AppData/Roaming/TestQuest/settings.txt"; print linux > "$C/users/$U/.config/testquest/x"; print slot > "$ST/common/TestQuest/Saves/slot1.sav"
EXE="$ST/common/TestQuest/TestQuest.exe"
paths=$(ct --save-paths Q "$EXE" 2>&1 | grep '^save ')
[[ "$paths" == *"save game: Test Quest"* && "$paths" == *"/TestQuest/save1.dat"* && "$paths" == *"/TestQuest/save2.dat"* && "$paths" == *"/common/TestQuest/Saves"* ]] || fail "save paths: $paths"
[[ "$paths" != *"settings.txt"* && "$paths" != *".config"* ]] || fail "paths the manifest doesn't name for Windows were included: $paths"
print -r -- "ok: $(print -r -- "$paths" | grep -c '^save path') save paths for Test Quest (app 555); settings.txt and the Linux-only path left out"
B="$TS/save-backups/Test Quest"
ct --backup-saves Q "$EXE" >/dev/null 2>&1; d=$(ls "$B" | tail -1)
[[ -f "$B/$d/users/$U/AppData/Roaming/TestQuest/save1.dat" && -f "$B/$d/Program Files (x86)/Steam/steamapps/common/TestQuest/Saves/slot1.sav" && ! -e "$B/$d/users/$U/AppData/Roaming/TestQuest/settings.txt" ]] || fail "backup content: $(cd "$B/$d" && find . -type f | tr '\n' ' ')"
print -r -- "ok: backup '$d' holds $(cd "$B/$d" && find . -type f | wc -l | tr -d ' ') files: $(cd "$B/$d" && find . -type f | sed 's|.*/||' | sort | tr '\n' ' ')"
ct --repair Q >/dev/null 2>&1; ls "$B" | grep -q ' before Repair$' || fail "no backup before Repair: $(ls "$B")"
print "ok: Repair backed the saves up first ($(ls "$B" | grep 'before Repair'))"
ct --bisect Q "$EXE" >/dev/null 2>&1; ls "$B" | grep -q ' before driver switch$' || fail "no backup before the driver switch: $(ls "$B")"
print "ok: a driver switch backed the saves up first ($(ls "$B" | grep 'before driver switch'))"
manifest 1026 101; ct --check-updates Q >/dev/null 2>&1; ls "$B" | grep -q ' before game update$' || fail "no backup before the game update: $(ls "$B")"
n=$(ls "$B" | grep -c 'before game update'); ct --check-updates Q >/dev/null 2>&1
(( $(ls "$B" | grep -c 'before game update') == n )) || fail "the same pending update was backed up twice"
print "ok: a pending Steam update (StateFlags 1026) backed the saves up once ($(ls "$B" | grep 'before game update'))"
for k in 1 2 3 4; do sleep 1; ct --backup-saves Q "$EXE" "extra $k" >/dev/null 2>&1; done
(( $(ls "$B" | grep -vc '^\.') == 5 )) || fail "kept $(ls "$B" | grep -vc '^\.') backups, expected the newest 5"
print "ok: the newest 5 backups are kept: $(ls "$B" | tr '\n' '|')"
tw_check || fail "your real data changed"
print "PASS save_backups"
