#!/bin/zsh
# Dock names: when Cosmopolitan Plays a Steam game while Steam is down, Wine is started as steam.exe -applaunch <id>, but the loader used
# to be named after the game ("The Witcher 3- Wild Hunt — Remastered" from ":"→"-"). macOS names the Dock after that file, and children
# inherit it for the whole Steam session. Loader must be "Steam". Also: sanitize no longer turns ":" into "-"; stale exact copies of
# bin/wine under old game titles are pruned (never non-wine files).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot

# --- Naming rules (no Wine yet) ---
ct --newbottle D >/dev/null 2>&1; [[ -d "$(tprefix D)/drive_c" ]] || fail "throwaway bottle D not created"
ST="$(tprefix D)/drive_c/Program Files (x86)/Steam"
GAME_DIR="$ST/steamapps/common/The Witcher 3"; mkdir -p "$GAME_DIR/bin" "$ST/steamapps"
# Colon in the Steam title is what produced "Witcher 3- Wild Hunt" under the old sanitizer.
# Fake appid (not 292030): skip ProtonDB/community winetricks so the live -applaunch path is what we measure.
printf '"AppState"\n{\n\t"appid"\t\t"9"\n\t"name"\t\t"The Witcher 3: Wild Hunt — Remastered"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"The Witcher 3"\n}\n' > "$ST/steamapps/appmanifest_9.acf"
cat > "$T/steam.c" <<'C'
#include <windows.h>
#include <stdio.h>
#include <string.h>
#define FLAG "C:\\Program Files (x86)\\Steam\\shutdown.flag"
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "-shutdown")) { FILE *f = fopen(FLAG, "w"); if (f) fclose(f); return 0; }
    FILE *s = fopen("C:\\Program Files (x86)\\Steam\\starts.txt", "a"); if (s) {
        fprintf(s, "start");
        for (int i = 1; i < argc; i++) fprintf(s, " %s", argv[i]);
        fprintf(s, "\n"); fclose(s);
    }
    DeleteFileA(FLAG);
    for (;;) { if (GetFileAttributesA(FLAG) != INVALID_FILE_ATTRIBUTES) { DeleteFileA(FLAG); return 0; } Sleep(250); }
}
C
cat > "$T/game.c" <<'C'
#include <windows.h>
int main(void) { Sleep(600000); return 0; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/steam.c" -o "$ST/steam.exe" || fail "build steam"
x86_64-w64-mingw32-gcc -O2 -s "$T/game.c" -o "$GAME_DIR/bin/witcher3.exe" || fail "build game"
# Direct non-Steam game for "keeps its own name"
PF="$(tprefix D)/drive_c/Program Files/Solo Game"; mkdir -p "$PF"
cp "$T/game.c" "$T/solo.c"; x86_64-w64-mingw32-gcc -O2 -s "$T/game.c" -o "$PF/Solo Game.exe" || fail "build solo"

BIN="$TS/engines/$ENGINE/wswine.bundle/bin"
# Seed the bad leftover the everyday engine had (exact copy of wine, colon→dash title).
BAD="The Witcher 3- Wild Hunt — Remastered"
cp "$BIN/wine" "$BIN/$BAD" || fail "seed bad loader"
# A non-wine file must never be pruned
print 'not wine' > "$BIN/keep-me-not-wine"
# A copy a running game was started from must stay (Wine starts that game's child processes through the same file).
BUSY="Busy Game"; cp "$BIN/wine" "$BIN/$BUSY" || fail "seed busy loader"
sandbox-exec -p "$(tw_sandbox_profile)" env HOME="$TH" WINEPREFIX="$(tprefix D)" WINEDEBUG=-all "$BIN/$BUSY" cmd.exe /c "ping -n 90 127.0.0.1 >nul" >/dev/null 2>&1 &
BUSYPID=$!
busy_up() { local p; for p in $(pgrep -f 'ping -n 90'); do return 0; done; return 1; }
poll 60 busy_up || fail "the busy stand-in did not start"

out=$(ct --loader-name D "$GAME_DIR/bin/witcher3.exe" 2>&1)
print -r -- "$out" | grep -q '^loader-name: Steam$' || fail "Steam game loader-name: $out"
print -r -- "$out" | grep -q '^loader-path: Steam$' || fail "Steam game loader-path (nbsp→print): $(print -r -- "$out" | grep loader-path)"
# Prune ran via loaderNamed: bad leftover gone; non-wine kept
[[ ! -e "$BIN/$BAD" ]] || fail "stale game-titled wine copy still in bin/: $BAD"
[[ -f "$BIN/keep-me-not-wine" ]] || fail "pruned a non-wine file"
[[ -f "$BIN/$BUSY" ]] || fail "pruned the loader copy a running game was started from"
kill $BUSYPID 2>/dev/null; twineserver D -k 2>/dev/null; wait $BUSYPID 2>/dev/null
print "ok: Steam game → loader-name Steam; pruned '$BAD'; left keep-me-not-wine and the running game's '$BUSY'"

out=$(ct --loader-name D "$ST/steam.exe" 2>&1)
print -r -- "$out" | grep -q '^loader-name: Steam$' || fail "steam.exe itself: $out"
out=$(ct --loader-name D "$PF/Solo Game.exe" 2>&1)
print -r -- "$out" | grep -q '^loader-name: Solo Game$' || fail "direct game should keep its name: $out"
# Sanitizer: colon must not become hyphen-space
[[ "$(print -r -- "$out")" != *"3-"* ]] || fail "sanitize still produces 3-: $out"
# Store host names
for pair in \
  "Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe:Epic Games" \
  "Program Files (x86)/Battle.net/Battle.net Launcher.exe:Battle.net" \
  "Program Files (x86)/GOG Galaxy/GalaxyClient.exe:GOG Galaxy" \
  "Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe:EA app" \
  "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe:Ubisoft Connect"
do
  rel=${pair%%:*}; want=${pair#*:}
  mkdir -p "$(tprefix D)/drive_c/${rel:h}"; print 'int main(void){return 0;}' > "$T/x.c"
  x86_64-w64-mingw32-gcc -O2 -s "$T/x.c" -o "$(tprefix D)/drive_c/$rel" 2>/dev/null || :   # may fail if path odd; stub empty file ok for name logic
  [[ -f "$(tprefix D)/drive_c/$rel" ]] || { mkdir -p "$(tprefix D)/drive_c/${rel:h}"; : > "$(tprefix D)/drive_c/$rel"; }
  out=$(ct --loader-name D "$(tprefix D)/drive_c/$rel" 2>&1)
  print -r -- "$out" | grep -q "^loader-name: ${want}$" || fail "store host $rel → want '$want': $out"
done
print "ok: store hosts and direct game naming"

# --- Live: Play Steam game with Steam down; process executable must be Steam, not the game title ---
ct --launch D "$GAME_DIR/bin/witcher3.exe" --wait 15 > "$T/launch.out" 2>&1 &
launch_pid=$!
# Same bottle-scoped Steam finder as steam_restart.sh (libproc / cwd under this throwaway prefix).
steampid() {
  local d="${$(tprefix D):A}" p cwd
  for p in $(pgrep -f 'Steam.steam\.exe' 2>/dev/null); do
    [[ "$p" == <-> ]] || continue
    cwd=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    [[ "$cwd" == "$d"/* ]] && { print -r -- "$p"; return 0; }
  done
  return 1
}
up() { steampid >/dev/null; }; poll 90 up || fail "Steam did not start for -applaunch: $(tail -30 "$T/launch.out"); starts=$(cat "$ST/starts.txt" 2>/dev/null)"
pid=$(steampid)
# macOS names the process after argv[0] / the Wine loader file. Prefer the bin/Steam mapping over other txt files (nls, dylibs).
exe_path=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | grep '/wswine.bundle/bin/' | head -1)
[[ -n "$exe_path" ]] || exe_path=$(ps -p "$pid" -o comm= 2>/dev/null)
base=${exe_path:t}
base_ascii=${base//$'\u00a0'/ }
[[ "$base_ascii" == "Steam" ]] || fail "steam.exe process executable is '$base' (path $exe_path), want Steam — pid=$pid comm=$(ps -p "$pid" -o comm=)"
[[ "$base_ascii" != *[Ww]itcher* && "$base_ascii" != *"3-"* ]] || fail "process still named after the game: $base"
grep -q -- '-applaunch' "$ST/starts.txt" 2>/dev/null \
  || fail "stand-in Steam was not started with -applaunch: $(cat "$ST/starts.txt" 2>/dev/null)"
[[ -x "$BIN/Steam" ]] || fail "engine bin/Steam loader missing after launch"
# `$ Steam …` is on the CLI's stdout (m.log), flushed when --launch exits — wait briefly then check.
cli_ok() { grep -E '^\$ Steam ' "$T/launch.out" >/dev/null 2>&1; }
poll 30 cli_ok || { wait $launch_pid 2>/dev/null; grep -E '^\$ Steam ' "$T/launch.out" >/dev/null \
  || fail "CLI did not start Wine as '\$ Steam …': $(grep '^\$ ' "$T/launch.out" | tail -5 | tr '\n' '|')"; }
[[ ! -e "$BIN/$BAD" ]] || fail "bad loader reappeared"
if ls "$BIN" | grep -F 'Witcher 3-' >/dev/null; then fail "bin/ still has a Witcher 3- loader: $(ls "$BIN" | tr '\n' ' ')"; fi
print "ok: live -applaunch process is Steam (pid $pid, exe=${base_ascii}); no game-titled loader"

twine D 'C:\Program Files (x86)\Steam\steam.exe' -shutdown >/dev/null 2>&1
kill $launch_pid 2>/dev/null; wait $launch_pid 2>/dev/null
tw_check || fail "your real data changed"
print "PASS dock_names"
