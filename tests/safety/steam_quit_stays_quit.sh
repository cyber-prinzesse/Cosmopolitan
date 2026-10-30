#!/bin/zsh
# Steam quit must stick. Two triggers from real bottles (see agents/cursor-report-steam-quit.md):
# 1) Wine Systray Hidden=1 (Sikarugir template) + ShowSystray=false → window-close has nowhere to minimize and Steam reopens the window.
# 2) Cosmopolitan's pending / in-flight restartSteam after the user Exits → bootstrap_log Shutdown then Startup 7–10 s later with Cosmo's -cef-* flags.
# Throwaway bottle only: stand-in steam.exe, never the user's Steam bottle.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot

# --- 1. Systray: template Hidden cleared when Steam is launched (steamBottleTweaks) ---
ct --newbottle Q >/dev/null 2>&1; [[ -d "$(tprefix Q)/drive_c" ]] || fail "throwaway bottle Q not created"
S="$(tprefix Q)/drive_c/Program Files (x86)/Steam"; mkdir -p "$S"
# Mimic Sikarugir/CrossOver template (user's everyday Steam bottle had both)
twine Q reg add 'HKCU\Software\Wine\Systray' /v Hidden /t REG_DWORD /d 1 /f >/dev/null 2>&1
twine Q reg add 'HKCU\Software\Wine\X11 Driver' /v ShowSystray /t REG_SZ /d false /f >/dev/null 2>&1
hid=$(twine Q reg query 'HKCU\Software\Wine\Systray' /v Hidden 2>/dev/null | tr -d '\r')
[[ "$hid" == *"0x1"* || "$hid" == *"0x00000001"* ]] || fail "could not seed Systray Hidden: $hid"
# On a real bottle the value has long been on disk; the app reads user.reg as text (no Wine call), so flush the registry now.
twineserver Q -k; twineserver Q -w
grep -A3 'Software\\\\Wine\\\\Systray' "$(tprefix Q)/user.reg" | grep -q '"Hidden"=dword:00000001' || fail "Systray Hidden not in user.reg after flush"
cat > "$T/steam.c" <<'C'
#include <windows.h>
#include <stdio.h>
#include <string.h>
#define FLAG "C:\\Program Files (x86)\\Steam\\shutdown.flag"
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "-shutdown")) { FILE *f = fopen(FLAG, "w"); if (f) fclose(f); return 0; }
    FILE *s = fopen("C:\\Program Files (x86)\\Steam\\starts.txt", "a"); if (s) { fprintf(s, "start %lu\n", GetCurrentProcessId()); fclose(s); }
    DeleteFileA(FLAG);
    for (;;) { if (GetFileAttributesA(FLAG) != INVALID_FILE_ATTRIBUTES) { DeleteFileA(FLAG); return 0; } Sleep(250); }
}
C
x86_64-w64-mingw32-gcc -O2 -s "$T/steam.c" -o "$S/steam.exe" || fail "could not build the stand-in"
ct --launch Q "$S/steam.exe" --wait 2 >/dev/null 2>&1
# healSteamSystray runs on steam.exe launch: Hidden must be gone
gone() { ! twine Q reg query 'HKCU\Software\Wine\Systray' /v Hidden 2>/dev/null | grep -q Hidden; }
poll 30 gone || fail "Systray Hidden still set after Steam launch: $(twine Q reg query 'HKCU\Software\Wine\Systray' /v Hidden 2>&1)"
print "ok: Steam's start cleared Systray Hidden in its own bottle (one wine reg call, only because it was set)"

steampid() { local d="${$(tprefix $1):A}" p; for p in $(pgrep -f 'Steam.steam\.exe'); do [[ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "$d"/* ]] && print $p; done; }
starts() { grep -c '^start' "$(tprefix $1)/drive_c/Program Files (x86)/Steam/starts.txt" 2>/dev/null || print 0; }
up() { [[ -n "$(steampid Q)" ]]; }; poll 60 up || fail "stand-in Steam did not start"
st0=$(steampid Q); [[ "$(starts Q)" == 1 ]] || fail "expected one start, got $(starts Q)"
print "ok: stand-in Steam running in Q (pid $st0)"

# --- 2. User quit cancels a pending idle-restart (must not Startup again with Cosmo flags) ---
manifest() { mkdir -p "$S/steamapps"; printf '"AppState"\n{\n\t"appid"\t\t"1"\n\t"name"\t\t"Fake Game"\n\t"StateFlags"\t\t"%s"\n\t"installdir"\t\t"FakeGame"\n}\n' $1 > "$S/steamapps/appmanifest_1.acf"; }
manifest 1026   # downloading → restart waits
# Idle poll every 1 s so the wait loop notices Steam gone quickly after quit (production uses 20 s).
COSMO_TEST_IDLE_POLL=1 ct --steam-restart Q "the test needs it" 90 > "$T/r.out" 2>&1 & rpid=$!
waited() { grep -q "Steam will restart once it's idle (downloading Fake Game now)" "$TH/Library/Logs/Cosmopolitan.log" 2>/dev/null; }
poll 60 waited || fail "pending restart never armed: $(tail -5 "$TH/Library/Logs/Cosmopolitan.log")"
print "ok: pending restart while downloading"
# User Exit: stand-in dies. The wait loop (and/or noteSteamRunningState) must cancel pending in that same process.
twine Q 'C:\Program Files (x86)\Steam\steam.exe' -shutdown >/dev/null 2>&1
down() { [[ -z "$(steampid Q)" ]]; }; poll 30 down || fail "stand-in did not shut down"
cancelled() { grep -q "Steam quit: cancelled a pending restart so it stays down" "$TH/Library/Logs/Cosmopolitan.log" 2>/dev/null; }
poll 30 cancelled || fail "user quit did not cancel pending restart: $(grep -E 'Steam|steam|pending' "$TH/Library/Logs/Cosmopolitan.log" | tail -16)"
# Stay down: no second start for ≥8 s (longer than the 7–10 s Shutdown→Startup gap in real logs)
sleep 8
[[ "$(starts Q)" == 1 ]] || fail "Steam came back after quit: starts=$(starts Q) pids=$(steampid Q) log=$(grep -E 'Restarting|cancelled|stayed quit' "$TH/Library/Logs/Cosmopolitan.log" | tail -8)"
[[ -z "$(steampid Q)" ]] || fail "Steam process still up after quit: $(steampid Q)"
kill $rpid 2>/dev/null; wait $rpid 2>/dev/null
print "ok: after user quit, pending restart cancelled and Steam stayed down (starts=1)"

# --- 3. Cosmopolitan's own restartSteam still relaunches when Cosmo stops Steam (steamStopOwned) ---
manifest 4; ct --launch Q "$S/steam.exe" --wait 2 >/dev/null 2>&1
up2() { [[ -n "$(steampid Q)" ]]; }; poll 60 up2 || fail "Steam did not come back for owned-restart check"
[[ "$(starts Q)" == 2 ]] || fail "expected starts=2 before Cosmo restart, got $(starts Q)"
out=$(ct --steam-restart Q "owned restart must work" 30 2>&1)
restarted() { [[ "$(starts Q)" == 3 && -n "$(steampid Q)" ]]; }
poll 60 restarted || fail "Cosmo restartSteam did not relaunch: starts=$(starts Q) out=$(print -r -- "$out" | tail -8)"
print "ok: Cosmopolitan-owned restartSteam still relaunches Steam (starts=3)"

tw_check || fail "your real data changed"
print "PASS steam_quit_stays_quit"
