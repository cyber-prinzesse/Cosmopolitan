#!/bin/zsh
# Strings a Windows program or a downloaded manifest controls must never reach the Mac shell or leave their folder.
# SEC-001: an appmanifest whose "appid" is shell text is not a Steam game (no identity, no cover-art fetch); a real numeric id still is.
# SEC-004: a Ludusavi game named ".." backs up into save-backups/game and its keep-5 prune never touches other support folders.
# SEC-006: Compress keeps the original game when ditto fails (it used to check `tail`'s exit status and delete the game anyway).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { chmod -R u+w "$TS/bottles" 2>/dev/null; print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle U >/dev/null 2>&1; [[ -d "$(tprefix U)/drive_c" ]] || fail "throwaway bottle not created"
ST="$(tprefix U)/drive_c/Program Files (x86)/Steam/steamapps"; mkdir -p "$ST/common/EvilGame" "$ST/common/GoodGame/Saves"
print 'int main(void){return 0;}' > "$T/g.c"; x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$T/g.exe" || fail "could not build the stand-in"
cp "$T/g.exe" "$ST/common/EvilGame/EvilGame.exe"; cp "$T/g.exe" "$ST/common/GoodGame/GoodGame.exe"; print slot > "$ST/common/GoodGame/Saves/slot1.sav"
# printf %s keeps the payload literal; it would create $T/PWNED if anything handed it to a shell.
printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"Evil"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"EvilGame"\n}\n' "7\$(touch $T/PWNED)" > "$ST/appmanifest_7.acf"
printf '"AppState"\n{\n\t"appid"\t\t"555"\n\t"name"\t\t"Good Game"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"GoodGame"\n}\n' > "$ST/appmanifest_555.acf"

st=$(ct --status U 2>&1)
[[ -e "$T/PWNED" ]] && fail "SEC-001: the appid payload ran in a shell"
print -r -- "$st" | grep -q 'steam:7' && fail "SEC-001: a non-numeric appid became a Steam identity: $(print -r -- "$st" | grep 'steam:7')"
print -r -- "$st" | grep -q 'steam:555' || fail "a real numeric appid lost its Steam identity: $(print -r -- "$st" | grep -i good)"
print "ok: SEC-001 appid '7\$(touch …)' rejected (no identity, nothing ran); app 555 still a Steam game"

cat > "$T/manifest.yaml" <<'Y'
..:
  files:
    "<base>/Saves":
      tags:
        - save
  steam:
    id: 555
Y
out=$(COSMO_TEST_URL_ludusavi="file://$T/manifest.yaml" ct --ludusavi-refresh 2>&1 | grep '^Ludusavi'); [[ "$out" == "Ludusavi manifest: 1 games." ]] || fail "refresh: $out"
mkdir -p "$TS/keep-me"; print data > "$TS/keep-me/file"
EXE="$ST/common/GoodGame/GoodGame.exe"
for k in 1 2 3 4 5 6 7; do sleep 1; ct --backup-saves U "$EXE" "run $k" >/dev/null 2>&1; done
[[ -f "$TS/keep-me/file" && -d "$(tprefix U)/drive_c" ]] || fail "SEC-004: the prune deleted support folders: $(ls "$TS")"
B="$TS/save-backups/game"; (( $(ls "$B" 2>/dev/null | grep -vc '^\.') == 5 )) || fail "SEC-004: backups not in save-backups/game (or not 5 kept): $(ls "$TS/save-backups" 2>&1)"
print "ok: SEC-004 game named '..' backs up into save-backups/game, 5 kept, support folders untouched"

G="$ST/common/GoodGame"; chmod a-w "$ST/common"
ct --compress U "$EXE" >/dev/null 2>&1; chmod u+w "$ST/common"
[[ -f "$G/GoodGame.exe" && -f "$G/Saves/slot1.sav" ]] || fail "SEC-006: a failed compress deleted the game: $(ls -la "$ST/common")"
[[ -e "$G.compressing" ]] && fail "SEC-006: half copy left behind"
print "ok: SEC-006 compress that cannot write its copy leaves the game as it was"
ct --compress U "$EXE" >/dev/null 2>&1
[[ -f "$G/GoodGame.exe" && "$(cat "$G/Saves/slot1.sav")" == slot ]] || fail "a normal compress lost files"
print "ok: a normal compress still works and keeps every file"

# SEC-002: a bottle name and a game folder that close a shell quote and run a command. Every shell path these modes use must keep them data.
N="Q'\$(touch $T/PWNED2)'"
ct --newbottle "$N" >/dev/null 2>&1; [[ -d "$(tprefix "$N")/drive_c" ]] || fail "SEC-002: bottle with a quote in its name was not created"
GQ="$(tprefix "$N")/drive_c/Games/It's '\$(touch $T/PWNED3)'"; mkdir -p "$GQ"; cp "$T/g.exe" "$GQ/Game.exe"
for m in --status --health --snapshot --snapshots --backup-shaders --cleanup-suggestions --repair; do ct $m "$N" >/dev/null 2>&1; done
ct --find "$N" >/dev/null 2>&1; ct --check "$N" "$GQ/Game.exe" >/dev/null 2>&1; ct --compress "$N" "$GQ/Game.exe" >/dev/null 2>&1
[[ -e "$T/PWNED2" || -e "$T/PWNED3" ]] && fail "SEC-002: a quote in a bottle or game folder name ran a command ($(ls $T | grep PWNED))"
[[ -f "$GQ/Game.exe" ]] || fail "SEC-002: the game in a quoted folder was lost"
print "ok: SEC-002 bottle \"$N\" and folder \"It's '\$(…)'\" went through status/health/snapshot/shaders/cleanup/repair/find/check/compress; nothing ran"
tw_check || fail "your real data changed"
print "PASS untrusted_input"
