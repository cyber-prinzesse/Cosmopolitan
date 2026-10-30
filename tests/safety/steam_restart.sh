#!/bin/zsh
# Item 24: no surprise Steam restarts. A stand-in Steam (exits when "steam.exe -shutdown" asks and starts the game on -applaunch, like
# Steam) runs in throwaway bottles T
# and U. While T's Steam downloads (an app manifest in a download state) or a game from steamapps\common runs in T, a requested restart
# waits and says so; once idle it restarts by itself. Starting a Steam game that needs Steam restarted asks first and does nothing on
# Cancel. Only T's Steam is ever stopped: U's Steam (same Windows path, other bottle) and your own Steam keep running.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
cat > "$T/steam.c" <<'C'
#include <windows.h>
#include <stdio.h>
#include <string.h>
#define FLAG "C:\\Program Files (x86)\\Steam\\shutdown.flag"
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "-shutdown")) { FILE *f = fopen(FLAG, "w"); if (f) fclose(f); return 0; }
    FILE *s = fopen("C:\\Program Files (x86)\\Steam\\starts.txt", "a"); if (s) { fprintf(s, "start %lu\n", GetCurrentProcessId()); fclose(s); }
    DeleteFileA(FLAG);
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "-applaunch")) {   /* like Steam: start the game from its own folder */
        STARTUPINFOA si = { sizeof si }; PROCESS_INFORMATION pi; char cmd[] = "\"C:\\Program Files (x86)\\Steam\\steamapps\\common\\FakeGame\\FakeGame.exe\"";
        if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, "C:\\Program Files (x86)\\Steam\\steamapps\\common\\FakeGame", &si, &pi)) { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    }
    for (;;) { if (GetFileAttributesA(FLAG) != INVALID_FILE_ATTRIBUTES) { DeleteFileA(FLAG); return 0; } Sleep(250); }
}
C
cat > "$T/game.c" <<'C'
#include <windows.h>
int main(void) { Sleep(600000); return 0; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/steam.c" -o "$T/steam.exe" && x86_64-w64-mingw32-gcc -O2 -s "$T/game.c" -o "$T/FakeGame.exe" || fail "could not build the stand-ins"
for b in T U; do
  ct --newbottle $b >/dev/null 2>&1; [[ -d "$(tprefix $b)/drive_c" ]] || fail "throwaway bottle $b not created"
  S="$(tprefix $b)/drive_c/Program Files (x86)/Steam"; mkdir -p "$S/steamapps/common/FakeGame"; cp "$T/steam.exe" "$S/"; cp "$T/FakeGame.exe" "$S/steamapps/common/FakeGame/"
done
ST="$(tprefix T)/drive_c/Program Files (x86)/Steam"; GAME="$ST/steamapps/common/FakeGame/FakeGame.exe"
manifest() { printf '"AppState"\n{\n\t"appid"\t\t"1"\n\t"name"\t\t"Fake Game"\n\t"StateFlags"\t\t"%s"\n\t"installdir"\t\t"FakeGame"\n}\n' $1 > "$ST/steamapps/appmanifest_1.acf"; }
steampid() { local d="${$(tprefix $1):A}" p; for p in $(pgrep -f 'Steam.steam\.exe'); do [[ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "$d"/* ]] && print $p; done; }
starts() { grep -c '^start' "$(tprefix $1)/drive_c/Program Files (x86)/Steam/starts.txt" 2>/dev/null || print 0; }
ct --launch T "$ST/steam.exe" --wait 2 >/dev/null 2>&1; ct --launch U "$(tprefix U)/drive_c/Program Files (x86)/Steam/steam.exe" --wait 2 >/dev/null 2>&1
up() { [[ -n "$(steampid T)" && -n "$(steampid U)" ]]; }; poll 60 up || fail "the stand-in Steams did not start"
st0=$(steampid T) su0=$(steampid U) real0=$(pgrep -f 'Steam.steam\.exe' | sort | tr '\n' ' ')
out=$(ct --steam-busy T 2>&1 | grep '^steam in'); [[ "$out" == "steam in T: running; idle" ]] || fail "busy check: $out"
print "ok: stand-in Steams running in T (pid $st0) and U (pid $su0); '$out'"
# Each bottle's store client is listed once: the selected bottle's Steam used to be added to every bottle's list (a duplicate the AVX scan crashed on).
lib=$(ct --status 2>&1 | grep '^library: '); [[ "$lib" == *", 0 listed twice" ]] || fail "the Library lists a program twice: $lib"
print -r -- "ok: $lib"

# 1. Downloading: the restart waits, then happens by itself once the download ends.
manifest 1026; out=$(ct --steam-busy T 2>&1 | grep '^steam in'); [[ "$out" == "steam in T: running; busy: downloading Fake Game" ]] || fail "busy check while downloading: $out"
COSMO_TEST_IDLE_POLL=1 ct --steam-restart T "the test needs it" 60 > "$T/r1.out" 2>&1 & rpid=$!
waited() { grep -q "Steam will restart once it's idle (downloading Fake Game now), so the test needs it." "$TH/Library/Logs/Cosmopolitan.log" 2>/dev/null; }
poll 60 waited || fail "the restart request never said it was waiting: $(tail -3 "$TH/Library/Logs/Cosmopolitan.log")"
alive() { kill -0 $1 2>/dev/null; }   # a restart ends the original process and adds a line to starts.txt
stay() { ! alive $st0 || [[ "$(starts T)" != 1 ]]; }; poll 5 stay && fail "T's Steam was restarted while it was downloading: alive $st0: $(alive $st0 && print yes || print no); starts: $(tr '\n' ' ' < "$ST/starts.txt"); log: $(grep -E 'Steam|steam' "$TH/Library/Logs/Cosmopolitan.log" | tail -8 | tr '\n' '|')"   # 5 s of polling for a wrong restart
print "ok: while downloading, the restart waited (T's Steam still pid $st0 after the request)"
manifest 4; restarted() { [[ "$(starts T)" == 2 && -n "$(steampid T)" ]]; }
poll 60 restarted || fail "T's Steam was not restarted after the download ended: $(tail -3 "$T/r1.out")"
kill $rpid 2>/dev/null; wait $rpid 2>/dev/null   # its job is done; the Steam it relaunched keeps running
L="$TH/Library/Logs/Cosmopolitan.log"; w=$(grep -n -m1 "Steam will restart once it's idle (downloading Fake Game now)" "$L" | cut -d: -f1); r=$(grep -n -m1 "Restarting Steam so the test needs it" "$L" | cut -d: -f1)
(( ${w:-0} > 0 && ${r:-0} > ${w:-0} )) || fail "the log does not show the wait, then the restart: $(grep -E 'Steam will|Restarting' "$L")"
st1=$(steampid T); print "ok: once the download ended Steam restarted by itself ${POLL_TOOK} s later (pid $st0 → $st1); U's Steam pid $(steampid U)"
alive $su0 || fail "U's Steam was stopped by T's restart"

# 2. A game from steamapps\common running in T: no restart.
# started straight with Wine from its folder, like Steam starts a game: Windows path as its command line, working folder in T
(cd "${GAME:h}" && twine T 'C:\Program Files (x86)\Steam\steamapps\common\FakeGame\FakeGame.exe' >/dev/null 2>&1 &)
gp() { pgrep -f 'FakeGame\\FakeGame\.exe'; }; poll 30 gp || fail "the stand-in game did not start"
out=$(ct --steam-restart T "the test needs it" 5 2>&1); [[ "$out" == *"Steam will restart once it's idle (a game is running now)"* && "$out" == *"pending restart: yes (a game is running)"* ]] || fail "with a game running: $out"
alive $st1 && [[ "$(starts T)" == 2 ]] || fail "T's Steam was restarted while a game ran"
print "ok: with a game running in T the restart waited (Steam still pid $st1)"
kill $(gp) 2>/dev/null; gone() { [[ -z "$(gp)" ]]; }; poll 30 gone

# 3. Starting a Steam game that needs Steam restarted (per-game env) while Steam downloads: asks; Cancel starts nothing.
manifest 1026; print 'FAKE_SETTING=1' > "$(tprefix T)/options/FakeGame.exe.env"
out=$(ct --launch T "$GAME" --wait 5 2>&1)
[[ "$out" == *"ASK: Restart Steam to start "*"Steam is downloading Fake Game."*"→ Cancel"* && "$out" == *"not started: Steam is downloading Fake Game."* ]] || fail "no question before restarting Steam: $(print -r -- "$out" | tail -12)"
[[ -z "$(gp)" && "$(starts T)" == 2 ]] && alive $st1 || fail "Cancel still restarted Steam or started the game"
print -r -- "ok: $(print -r -- "$out" | grep -o 'ASK: .*' | head -1)"
print "ok: on Cancel nothing happened (Steam still pid $st1, the game not started)"
COSMO_TEST_ANSWER=yes ct --launch T "$GAME" --wait 30 > "$T/yes.out" 2>&1
poll 30 gp || fail "after 'Restart Steam' the game did not start (starts: $(starts T)): $(tail -15 "$T/yes.out")"
[[ "$(starts T)" == 3 ]] || fail "after 'Restart Steam' Steam was not restarted"
print "ok: after 'Restart Steam' Steam restarted (pid $(steampid T)) and the game started"
kill $(gp) 2>/dev/null

alive $su0 || fail "U's Steam was stopped"
real1=$(pgrep -f 'Steam.steam\.exe' | sort | tr '\n' ' '); for p in ${=real0}; do [[ "$p" == "$st0" || "$p" == "$st1" || "$p" == "$su0" ]] && continue; kill -0 $p 2>/dev/null || fail "a Steam outside the test (pid $p) was stopped"; done
print "ok: U's Steam (pid $su0) and every Steam outside the test kept running throughout"
tw_check || fail "your real data changed"
print "PASS steam_restart"
