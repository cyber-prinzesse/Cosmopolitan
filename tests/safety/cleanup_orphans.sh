#!/bin/zsh
# testenv_cleanup must kill native stand-ins AND Wine programs under this run's $T/ (not only wineservers), including on
# fail() and SIGTERM, without touching a control process started from a different cosmotest.* folder.
# Wine rewrites argv to C:\… so cleanup must match by executable path (proc_pidpath), and must wineserver -k before kill.
source "${0:A:h}/../lib/testenv.sh"
fail() { print "FAIL: $*"; exit 1; }

# Busy x86_64 loop (same shape as fault_loop's busy-standin). Built outside any cosmotest.* tree.
BUILD=$(mktemp -d /tmp/cosmo-orphan-build.XXXXXX) || fail "mktemp build"
trap 'rm -rf "$BUILD"' EXIT
cat > "$BUILD/busy.c" <<'C'
int main(void) { volatile unsigned long long x = 0; for (;;) x++; return 0; }
C
clang -arch x86_64 -O0 -o "$BUILD/busy" "$BUILD/busy.c" || fail "could not build busy stand-in (need Rosetta / x86_64 clang)"

still_alive() { kill -0 "$1" 2>/dev/null; }
orphans_under() { _testenv_pids_under_T "$1" 2>/dev/null || true; }
# macOS has no setsid(1): double-fork + setsid(2) so the stand-in is reparented (launchd) and ignores the test shell's SIGHUP.
detach_under() {
  python3 -c '
import os, sys
path = sys.argv[1]
if os.fork() > 0: sys.exit(0)
os.setsid()
if os.fork() > 0: os._exit(0)
os.chdir("/")
os.execv(path, [path])
' "$1"
}

# --- (c) control in a DIFFERENT throwaway folder (must survive the cases below) ---
CTRL=$(mktemp -d /private/tmp/cosmotest.XXXXXX) || fail "mktemp control"
_testenv_t_ok "$CTRL" || fail "control path rejected: $CTRL"
cp "$BUILD/busy" "$CTRL/control-standin"
"$CTRL/control-standin" &
CTRLPID=$!
sleep 0.3
still_alive $CTRLPID || fail "control stand-in did not start"

# --- (a) fail(): busy + detached grandchild under $T, then fail() ---
T_A_FILE="$BUILD/ta"
(
  unset TESTENV_CLEANED
  TESTENV_NO_ENGINE=1
  testenv_init >/dev/null || exit 1
  eval "$(testenv_trap_cleanup)"
  [[ -d "$T" ]] || { print -u2 "FAIL: \$T missing after init"; exit 2; }
  cp "$BUILD/busy" "$T/busy-standin" || exit 2
  mkdir -p "$T/helpers"
  cp "$BUILD/busy" "$T/helpers/grandchild-standin" || exit 2
  "$T/busy-standin" &
  detach_under "$T/helpers/grandchild-standin"
  sleep 0.5
  orphans_under "$T" | grep -q . || { print -u2 "FAIL: stand-ins not running before fail()"; exit 2; }
  print -r -- "$T" > "$T_A_FILE"
  fail "forced fail for cleanup_orphans (a)"
)
ec_a=$?
[[ $ec_a -eq 1 ]] || fail "phase (a): expected exit 1 from fail(), got $ec_a"
T_A=$(cat "$T_A_FILE")
sleep 0.3
left_a=$(orphans_under "$T_A")
[[ -z "$left_a" ]] || fail "phase (a): orphans still under $T_A: $left_a"
still_alive $CTRLPID || fail "phase (a): control process in $CTRL was killed"
print "ok: fail() cleanup killed busy + detached grandchild under $T_A; control survived"

# --- (b) SIGTERM mid-run: separate zsh process with sleep & wait $! so the trap runs immediately ---
# (zsh defers traps until a foreground child exits; a bare `sleep 120` would ignore TERM until it finishes.)
T_B_FILE="$BUILD/tb"
: > "$T_B_FILE"
cat > "$BUILD/phase_b.sh" <<EOF
#!/bin/zsh
source "${TESTENV_REPO}/tests/lib/testenv.sh"
unset TESTENV_CLEANED
TESTENV_NO_ENGINE=1
testenv_init >/dev/null || exit 1
eval "\$(testenv_trap_cleanup)"
cp "$BUILD/busy" "\$T/busy-standin" || exit 2
mkdir -p "\$T/helpers"
cp "$BUILD/busy" "\$T/helpers/grandchild-standin" || exit 2
"\$T/busy-standin" &
# detached grandchild (same helper as the parent script)
python3 -c '
import os, sys
path = sys.argv[1]
if os.fork() > 0: sys.exit(0)
os.setsid()
if os.fork() > 0: os._exit(0)
os.chdir("/")
os.execv(path, [path])
' "\$T/helpers/grandchild-standin"
sleep 0.5
print -r -- "\$T" > "$T_B_FILE"
# Background sleep + wait: TERM interrupts wait and runs the trap immediately.
sleep 120 &
wait \$!
EOF
zsh "$BUILD/phase_b.sh" >/dev/null 2>"$BUILD/phase_b.err" &
SUB=$!
poll 30 test -s "$T_B_FILE" || { print -r -- "phase_b.err: $(cat "$BUILD/phase_b.err" 2>/dev/null)"; fail "phase (b): child never wrote \$T"; }
T_B=$(cat "$T_B_FILE")
orphans_under "$T_B" | grep -q . || fail "phase (b): stand-ins not running before SIGTERM"
kill -TERM $SUB 2>/dev/null
phase_b_gone() { ! kill -0 $SUB 2>/dev/null; }
# cleanup sleeps ~2 s after TERM; allow headroom
poll 20 phase_b_gone || { kill -KILL $SUB 2>/dev/null; fail "phase (b): helper still alive after SIGTERM"; }
wait $SUB 2>/dev/null
sleep 0.5
left_b=$(orphans_under "$T_B")
[[ -z "$left_b" ]] || fail "phase (b): orphans still under $T_B after SIGTERM: $left_b"
still_alive $CTRLPID || fail "phase (b): control process in $CTRL was killed"
print "ok: SIGTERM cleanup killed stand-ins under $T_B; control survived"

# --- (d) Wine: notepad + CreateProcess child, fail() — must leave nothing with exe under $T/ ---
# On the old argv-based cleanup this leaked: Windows argv never starts with $T/, and wineserver was killed first.
T_D_FILE="$BUILD/td"
(
  unset TESTENV_CLEANED
  testenv_init >/dev/null || exit 1
  eval "$(testenv_trap_cleanup)"
  ct --newbottle W >/dev/null 2>&1
  [[ -d "$(tprefix W)/drive_c" ]] || { print -u2 "FAIL: bottle W missing"; exit 2; }
  PF="$(tprefix W)/drive_c/Program Files/HostApp"; mkdir -p "$PF"
  cat > "$T/host.c" <<'C'
#include <windows.h>
int main(void){ STARTUPINFOA si={sizeof si}; PROCESS_INFORMATION pi;
  CreateProcessA(NULL,"C:\\windows\\system32\\notepad.exe",NULL,NULL,FALSE,0,NULL,NULL,&si,&pi);
  Sleep(600000); return 0; }
C
  x86_64-w64-mingw32-gcc -O2 -s "$T/host.c" -o "$PF/HostApp.exe" || { print -u2 "FAIL: build HostApp"; exit 2; }
  ct --launch W "$PF/HostApp.exe" --wait 2 >/dev/null 2>&1 &
  # Wait until notepad exists with a Windows argv (the leak class the old argv matcher missed).
  wine_child() { ps -axo pid=,command= | awk '$2 ~ /^C:.windows.system32.notepad.exe/{print $1; exit}'; }
  for i in {1..40}; do sleep 0.5; [[ -n "$(wine_child)" ]] && break; done
  [[ -n "$(wine_child)" ]] || { print -u2 "FAIL: HostApp did not start notepad before fail()"; exit 2; }
  # Confirm exe-path match sees the Wine loaders under $T.
  orphans_under "$T" | grep -q . || { print -u2 "FAIL: no processes under \$T before Wine fail()"; exit 2; }
  print -r -- "$T" > "$T_D_FILE"
  fail "forced fail for cleanup_orphans (d) Wine"
)
ec_d=$?
[[ $ec_d -eq 1 ]] || fail "phase (d): expected exit 1 from fail(), got $ec_d"
T_D=$(cat "$T_D_FILE")
sleep 1
left_d=$(orphans_under "$T_D")
[[ -z "$left_d" ]] || fail "phase (d): Wine orphans still under $T_D: $left_d"
# Also no stray notepad/HostApp whose exe path still points at the deleted tree (proc_pidpath).
for p in $(ps -axo pid=); do
  [[ "$p" == <-> ]] || continue
  exe=$(_testenv_pid_exe "$p" 2>/dev/null) || continue
  [[ "$exe" == "$T_D/"* ]] && fail "phase (d): pid $p still running from deleted tree: $exe"
done
still_alive $CTRLPID || fail "phase (d): control process in $CTRL was killed"
print "ok: fail() cleanup stopped Wine HostApp+notepad under $T_D; control survived"

# --- control still alive; tear it down ourselves (exact pid — never a broad pgrep) ---
still_alive $CTRLPID || fail "control died unexpectedly"
kill -TERM $CTRLPID 2>/dev/null
sleep 0.5
kill -KILL $CTRLPID 2>/dev/null
wait $CTRLPID 2>/dev/null
rm -rf "$CTRL"
print "ok: control from a different cosmotest.* folder was never reaped by another run's cleanup"
print "PASS cleanup_orphans"
