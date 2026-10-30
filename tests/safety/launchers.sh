#!/bin/zsh
# Item 37: a Dock/Launchpad entry per game. Two stand-in games; --sync-launchers writes one launcher app each into the throwaway home's
# ~/Applications/Cosmopolitan Apps: signed, marked as Cosmopolitan's, opening cosmopolitan://launch?name=… with this app. A removed game's
# launcher goes; an app there that isn't ours stays. Launchers are never run here (they would reach the Cosmopolitan registered for the link).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle L >/dev/null 2>&1; [[ -d "$(tprefix L)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix L)/drive_c/Program Files"; print 'int main(void){return 0;}' > "$T/g.c"
for g in "Alpha Game" "Beta Game" "Gamma Game" "Delta: Game"; do mkdir -p "$PF/$g"; x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$PF/$g/$g.exe" || fail "could not build $g"; done
D="$TH/Applications/Cosmopolitan Apps"; mkdir -p "$D/Other.app/Contents"; print '<plist version="1.0"><dict><key>CFBundleName</key><string>Other</string></dict></plist>' > "$D/Other.app/Contents/Info.plist"
mkdir -p "$D/Gamma Game.app/Contents/MacOS"; print '#!/bin/sh\n# yours' > "$D/Gamma Game.app/Contents/MacOS/launch"   # a launcher you made yourself
out=$(ct --sync-launchers 2>&1 | grep -E '^(Dock|Entries)')
[[ "$(cat "$D/Gamma Game.app/Contents/MacOS/launch")" == *"# yours"* && "$out" != *"Gamma Game"* ]] || fail "your own Gamma Game.app was replaced: $out"
A="$D/Alpha Game.app"
grep -q 'cosmopolitan://launch?name=Alpha%20Game' "$A/Contents/MacOS/launch" && grep -q "open -a '$T/CosmopolitanTest.app'" "$A/Contents/MacOS/launch" || fail "launcher script: $(cat "$A/Contents/MacOS/launch")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CosmopolitanLauncher' "$A/Contents/Info.plist")" == true ]] && codesign -v "$A" 2>/dev/null || fail "Alpha Game.app not marked or not signed"
[[ -d "$D/Beta Game.app" ]] || fail "no launcher for Beta Game"
# ":" shows as "/" in Finder and Launchpad ("Delta/ Game"): the launcher file drops it; the link still names the game exactly.
[[ -d "$D/Delta Game.app" && ! -e "$D/Delta: Game.app" ]] || fail "launcher for 'Delta: Game' not named 'Delta Game.app': $(ls "$D" | tr '\n' ' ')"
grep -q 'cosmopolitan://launch?name=Delta:%20Game' "$D/Delta Game.app/Contents/MacOS/launch" || fail "Delta launcher link: $(grep '^open' "$D/Delta Game.app/Contents/MacOS/launch")"
print "ok: 'Delta: Game' got 'Delta Game.app' (no ':' shown as '/'), launching the game by its real name"
print -r -- "ok: $out"
print -r -- "  Alpha Game.app runs: $(grep '^open' "$A/Contents/MacOS/launch" | sed "s|$T|<test>|g")"
rm -rf "$PF/Beta Game"; out=$(ct --sync-launchers 2>&1 | grep -E '^(Dock|Entries)')
[[ ! -e "$D/Beta Game.app" && -d "$A" && -d "$D/Other.app" ]] || fail "after removing Beta Game: $(ls "$D" | tr '\n' ' ')"
print -r -- "ok: $out (Alpha Game.app kept; Other.app, not ours, untouched)"
print "ok: a launcher you made for a Library game (Gamma Game.app, unmarked) was left as it was"
tw_check || fail "your real data changed"
print "PASS launchers"
