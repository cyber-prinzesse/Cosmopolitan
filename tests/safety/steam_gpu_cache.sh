#!/bin/zsh
# An engine change updates the prefix; just before that the app deletes Steam's browser GPU caches (GrShaderCache, ShaderCache,
# GraphiteDawnCache), which kept Steam blank on Cosmos after a move from another engine. Everything else in htmlcache stays.
#  A. Steam's browser running in the bottle (a stand-in named steamwebhelper.exe): nothing is deleted.
#  B. Nothing running: the three caches go, the rest of htmlcache stays.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle G >/dev/null 2>&1; P="$(tprefix G)"; [[ -d "$P/drive_c" ]] || fail "throwaway bottle not created"
u=$(ls "$P/drive_c/users" | grep -v '^Public$' | head -1); [[ -n "$u" ]] || fail "no user folder in the bottle"
H="$P/drive_c/users/$u/AppData/Local/Steam/htmlcache"
caches=(GrShaderCache ShaderCache GraphiteDawnCache)
seed() { for d in $caches Default; do mkdir -p "$H/$d"; print x > "$H/$d/data"; done; }
seed

# A. Steam's browser running there. Started from inside the bottle, as the app starts programs (it tells bottles apart by working folder).
print '#include <windows.h>\nint main(void) { Sleep(600000); return 0; }' > "$T/sleep.c"
mkdir -p "$P/drive_c/Steam"; x86_64-w64-mingw32-gcc -O2 -s "$T/sleep.c" -o "$P/drive_c/Steam/steamwebhelper.exe" || fail "no stand-in"
(cd "$P/drive_c/Steam" && twine G 'C:\Steam\steamwebhelper.exe') >/dev/null 2>&1 &
inside() { pgrep -f '^C:.*steamwebhelper\.exe' | while read p; do [[ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "${P:A}"* ]] && print $p; done; }
starts() { twine G cmd /c echo started 2>/dev/null | tr -d "\r" | grep -q started; }
up() { [[ -n "$(tserverpid G)" && -n "$(inside)" ]]; }; poll 60 up && poll 60 starts || fail "the stand-in did not start inside the bottle"
print 1 > "$P/.update-timestamp"
ct --print-env G >/dev/null 2>&1
for d in $caches; do [[ -f "$H/$d/data" ]] || fail "A: $d deleted while Steam's browser was running"; done
print "ok: A. with Steam's browser running, its caches were left alone"
for p in $(inside); do kill $p; done; twineserver G -k; poll 30 eval '[[ -z "$(tserverpid G)" ]]'

# B. Nothing running.
seed; print 1 > "$P/.update-timestamp"
ct --print-env G >/dev/null 2>&1
[[ "$(cat "$P/.update-timestamp")" != 1 ]] || fail "B: the prefix was not updated"
for d in $caches; do [[ ! -e "$H/$d" ]] || fail "B: $d still there after the engine update"; done
[[ -f "$H/Default/data" ]] || fail "B: the rest of htmlcache was deleted"
print "ok: B. the engine update removed the three GPU caches and kept the rest of htmlcache"
twineserver G -k
tw_check || fail "your real data changed"
print "PASS steam_gpu_cache"
