#!/bin/zsh
# Mac Quit hand-over (Wine 10 Dock add-on): a Dock / Cmd-Q quit of a program with Mac Driver › QuitRuns runs that Windows command
# instead of ending only that process. Steam's Dock icon belongs to steamwebhelper.exe; quitting it alone made steam.exe start a
# new helper at once, so Steam never stayed closed (2026-10-31). The app sets QuitRuns="…\steam.exe -shutdown" for it.
# Stand-in: notepad with QuitRuns = cmd writing a marker file. The quit is the same Apple event the Dock sends
# (NSRunningApplication.terminate). Throwaway engine copy and bottle only (testenv.sh).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
testenv_engine_has_dock_patches && { print -r -- "skip ${0:t:r}: $ENGINE has the Dock patches (0029/0030), the app installs no add-on into it"; print "PASS ${0:t:r}"; exit 0; }
tw_snapshot
E="$TS/engines/$ENGINE/wswine.bundle"; U="$E/lib/wine/x86_64-unix"
# Start from the engine's own driver (the real engine may already carry an older add-on), then install this build's.
[[ -f "$U/winemac.so.orig-before-nodock" ]] && { cp "$U/winemac.so.orig-before-nodock" "$U/winemac.so"; rm -f "$U/winemac.so.orig-before-nodock"; }
rm -f "$U/cosmo_nodock.dylib" "$U/cosmo_exeIcon.icns"
out=$(ct --nodock-engine "$E" 2>&1); [[ "$out" == *"NoDockIcon"* ]] || fail "add-on not installed: $out"
cmp -s "$U/cosmo_nodock.dylib" "$TESTENV_REPO/build.noindex/Cosmopolitan.app/Contents/Resources/cosmo_nodock.dylib" || fail "engine add-on is not this build's"

cat > "$T/macquit.swift" <<'W'
import AppKit
guard let a = NSRunningApplication(processIdentifier: pid_t(CommandLine.arguments[1])!) else { exit(2) }
exit(a.terminate() ? 0 : 1)
W
swiftc -O -o "$T/macquit" "$T/macquit.swift" 2>/dev/null || fail "build macquit"

ct --newbottle Q >/dev/null 2>&1; [[ -d "$(tprefix Q)/drive_c" ]] || fail "throwaway bottle Q not created"
start_notepad() {   # prints notepad's pid once it is a Dock app
  twine Q notepad.exe >/dev/null 2>&1 &
  local p="" i
  for i in {1..40}; do sleep 0.5
    p=$(ps -axo pid=,command= | awk '/notepad\.exe/ && !/awk/ {print $1; exit}')
    [[ -n "$p" ]] && lsappinfo list | grep "pid = $p " | grep -q 'type="Foreground"' && { print $p; return 0; }
  done; return 1; }
gone() { ! kill -0 $1 2>/dev/null; }
poll() { local n=$1 i; shift; for ((i=0; i<n*2; i++)); do "$@" && return 0; sleep 0.5; done; return 1; }

# 1. No QuitRuns: Wine's own quit ends the program.
np=$(start_notepad) || fail "notepad did not become a Dock app"
"$T/macquit" $np || fail "quit event not accepted"
poll 15 gone $np || fail "without QuitRuns a Mac quit should end notepad (pid $np still running)"
print "ok: without QuitRuns a Mac quit ends the program (Wine's own handling)"
twineserver Q -w

# 2. QuitRuns: the command runs, the program itself is not ended by the quit.
M="$(tprefix Q)/drive_c/quit-ran.txt"; rm -f "$M"
twine Q reg add 'HKCU\Software\Wine\AppDefaults\notepad.exe\Mac Driver' /v QuitRuns /d 'C:\windows\system32\cmd.exe /c echo ran>C:\quit-ran.txt' /f >/dev/null 2>&1
twineserver Q -w   # user.reg on disk: the add-on reads it there
grep -q '"QuitRuns"=' "$(tprefix Q)/user.reg" || fail "QuitRuns not in user.reg"
np=$(start_notepad) || fail "notepad did not become a Dock app (QuitRuns leg)"
"$T/macquit" $np || fail "quit event not accepted (QuitRuns leg)"
poll 30 test -s "$M" || fail "QuitRuns command did not run on Mac quit"
sleep 2; gone $np && fail "notepad ended itself; the quit should have been handed to QuitRuns"
print "ok: with QuitRuns a Mac quit runs the command and leaves the program to it"
twineserver Q -k; sleep 1

tw_check
print "PASS mac_quit_runs"
