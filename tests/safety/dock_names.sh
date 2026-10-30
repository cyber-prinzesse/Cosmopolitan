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
print -r -- "$out" | grep -q '^loader-path: cosmo_wineloader$' || fail "Steam game loader-path (dispatcher): $(print -r -- "$out" | grep loader-path)"
[[ -x "$BIN/cosmo_wineloader" ]] || fail "cosmo_wineloader missing after --loader-name"
[[ -x "$BIN/Steam" ]] || fail "host wine copy bin/Steam missing after --loader-name"
# Prune ran via loaderNamed: bad leftover gone; non-wine kept; in-use copy kept
[[ ! -e "$BIN/$BAD" ]] || fail "stale game-titled wine copy still in bin/: $BAD"
[[ -f "$BIN/keep-me-not-wine" ]] || fail "pruned a non-wine file"
[[ -f "$BIN/$BUSY" ]] || fail "pruned the loader copy a running game was started from"
kill $BUSYPID 2>/dev/null; twineserver D -k 2>/dev/null; wait $BUSYPID 2>/dev/null
print "ok: Steam game → loader-name Steam via cosmo_wineloader; pruned '$BAD'; left keep-me-not-wine and '$BUSY'"

out=$(ct --loader-name D "$ST/steam.exe" 2>&1)
print -r -- "$out" | grep -q '^loader-name: Steam$' || fail "steam.exe itself: $out"
print -r -- "$out" | grep -q '^loader-path: cosmo_wineloader$' || fail "steam.exe loader-path: $out"
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

# Game child through the dispatcher (what Wine CreateProcess does with WINELOADER): own Dock label; Steam keeps "Steam".
mkdir -p "$(tprefix D)/options"
print $'childgame.exe\tChild Game Label' > "$(tprefix D)/options/dock-names.txt"
cp "$(tprefix D)/drive_c/windows/system32/notepad.exe" "$GAME_DIR/bin/childgame.exe"
sandbox-exec -p "$(tw_sandbox_profile)" env HOME="$TH" CFFIXED_USER_HOME="$TH" \
  WINEPREFIX="$(tprefix D)" WINEDEBUG=-all WINEMSYNC=1 \
  WINELOADER="$BIN/cosmo_wineloader" COSMO_LOADER_NAME=Steam \
  "$BIN/cosmo_wineloader" "C:\\Program Files (x86)\\Steam\\steamapps\\common\\The Witcher 3\\bin\\childgame.exe" >/dev/null 2>&1 &
CHILD_LP=$!
dock_ascii() { osascript -e 'tell application "System Events" to get name of every UI element of list 1 of application process "Dock"' 2>/dev/null | sed $'s/\u00a0/ /g'; }
child_up() {
  local p labels
  p=$(ps -axo pid=,command= | awk '/childgame\.exe/ && !/awk/ {print $1; exit}')
  [[ -n "$p" ]] || return 1
  lsappinfo list | grep "pid = $p " | grep -q 'type="Foreground"' || return 1
  labels=$(dock_ascii)
  print -r -- "$labels" | grep -F 'Child Game Label' >/dev/null
}
poll 60 child_up || fail "game child did not get Dock label 'Child Game Label'"
dock_now=$(dock_ascii)
print -r -- "$dock_now" | grep -F 'Steam' >/dev/null || fail "Steam Dock label gone while child ran: $dock_now"
print -r -- "$dock_now" | grep -F 'Child Game Label' >/dev/null || fail "child Dock label missing: $dock_now"
# Child's loader file must be the named copy, not cosmo_wineloader / wine.
cpid=$(ps -axo pid=,command= | awk '/childgame\.exe/ && !/awk/ {print $1; exit}')
cpath=$(lsof -a -p "$cpid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | grep '/wswine.bundle/bin/' | head -1)
cbase=${cpath:t}; cbase=${cbase//$'\u00a0'/ }
[[ "$cbase" == "Child Game Label" ]] || fail "child loader file is '$cbase' (path $cpath), want 'Child Game Label'"
kill $CHILD_LP 2>/dev/null; wait $CHILD_LP 2>/dev/null
print "ok: Steam -applaunch host stays Steam; game child Dock label is its dock-names entry"

twine D 'C:\Program Files (x86)\Steam\steam.exe' -shutdown >/dev/null 2>&1
kill $launch_pid 2>/dev/null; wait $launch_pid 2>/dev/null
twineserver D -k 2>/dev/null
tw_check || fail "your real data changed"
print "ok: Wine 10 dock-label dispatcher"

# Wine 11 (highball): unix/wine becomes the dispatcher; named copies live beside ntdll.
R29="$REAL_HOME/Library/Application Support/Cosmopolitan Beta/engines/highball-11.0-r29"
[[ -d "$R29/wswine.bundle" ]] || R29="$REAL_HOME/Cosmopolitan-engine-trials/highball-11.0-r29"
if [[ -e "$R29/wswine.bundle/lib/wine/x86_64-unix/wine" || -e "$R29/engine/lib/wine/x86_64-unix/wine" ]]; then
  testenv_cleanup
  COSMO_ENGINE=highball-11.0-r29 COSMO_ENGINE_DIR="$R29" testenv_init >/dev/null || fail "Wine 11 testenv"
  eval "$(testenv_trap_cleanup)"
  tw_snapshot
  ct --newbottle W11 >/dev/null 2>&1
  U11="$TS/engines/$ENGINE/wswine.bundle/lib/wine/x86_64-unix"
  out=$(ct --loader-name W11 "$(tprefix W11)/drive_c/windows/system32/notepad.exe" 2>&1)
  print -r -- "$out" | grep -q '^loader-path: cosmo_wineloader$' || fail "Wine 11 loader-path: $out"
  [[ -x "$U11/wine" ]] || fail "Wine 11: missing unix/wine"
  strings "$U11/wine" | grep -q cosmo_dock_loader_v1 || fail "Wine 11: unix/wine is not the dispatcher"
  [[ -f "$U11/wine.cosmo-real" ]] || fail "Wine 11: wine.cosmo-real backup missing"
  tw_check || fail "your real data changed after Wine 11 check"
  print "ok: Wine 11 unix/wine is cosmo_wineloader (real loader backed up)"
else
  print "note: highball-11 not on this Mac; skipped Wine 11 dispatcher check"
fi
print "PASS dock_names"
