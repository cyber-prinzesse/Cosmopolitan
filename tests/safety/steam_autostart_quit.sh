#!/bin/zsh
# Autostart respects your quit: once you quit Steam (Steam exits and Cosmopolitan did not stop it itself), the next Cosmopolitan
# start does not bring Steam back; once Steam runs again (any starter), autostart is back on. 2026-10-31: Steam came back
# after Cosmopolitan restarted for an update. Marker <bottle>/options/.steam-user-quit; no Wine session needed.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot

ct --newbottle S >/dev/null 2>&1; [[ -d "$(tprefix S)/drive_c" ]] || fail "throwaway bottle not created"
ST="$(tprefix S)/drive_c/Program Files (x86)/Steam"; mkdir -p "$ST"; : > "$ST/steam.exe"
M="$(tprefix S)/options/.steam-user-quit"
skips() { ct --settings S 2>&1 | sed -n 's/^steam quit by user  → autostart skips [^:]*: //p'; }

[[ ! -e "$M" && "$(skips)" == false ]] || fail "fresh bottle should autostart (marker=$([[ -e $M ]] && print yes || print no), skips=$(skips))"
print -r -- "ok: fresh bottle → autostart on"

# Steam was up, now gone, not stopped by Cosmopolitan → your quit.
out=$(COSMO_TEST_APP_INACTIVE=1 COSMO_TEST_STEAM_EXIT_DELAY=0 ct --steam-exit-sync S 2>&1)
[[ -e "$M" ]] || fail "user quit not remembered: $out"
[[ "$(skips)" == true ]] || fail "autostart should skip after your quit: $(ct --settings S 2>&1 | grep -i steam)"
print -r -- "ok: you quit Steam → next start leaves it closed"

# A tick while Steam is still down keeps the marker (Cosmopolitan restarting for an update).
out=$(ct --steam-watch-tick S 2>&1)
[[ -e "$M" ]] || fail "marker dropped while Steam stayed down: $out"
print -r -- "ok: Cosmopolitan restart with Steam still down → stays closed"

# Steam runs again (you started it): the first tick that sees it clears the marker.
out=$(COSMO_TEST_STEAM_RUNNING=1 ct --steam-watch-tick S 2>&1)
[[ ! -e "$M" ]] || fail "marker kept although Steam runs again: $out"
[[ "$(skips)" == false ]] || fail "autostart should be back on once Steam ran again"
print -r -- "ok: Steam running again → autostart back on"

tw_check || fail "your real data changed"
print "PASS steam_autostart_quit"
