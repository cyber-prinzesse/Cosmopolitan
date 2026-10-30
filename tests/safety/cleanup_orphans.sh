#!/bin/zsh
# testenv_cleanup must kill native stand-ins under this run's $T/ (not only wineservers), including on fail() and SIGTERM,
# without touching a control process started from a different cosmotest.* folder.
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

# --- (b) SIGTERM mid-run ---
# zsh signal traps do not run under this agent runner (TERM/INT/USR1 verified no-ops; Python handlers work).
# A Python holder installs a real SIGTERM handler that runs testenv_cleanup for the throwaway T it started.
T_B_FILE="$BUILD/tb"
: > "$T_B_FILE"
cat > "$BUILD/phase_b.py" <<'PY'
import os, signal, subprocess, sys, time

repo, build, tb = sys.argv[1], sys.argv[2], sys.argv[3]
busy = os.path.join(build, "busy")
env = os.environ.copy()
env["TESTENV_NO_ENGINE"] = "1"
init = subprocess.run(
    ["zsh", "-c", f"""
source '{repo}/tests/lib/testenv.sh'
unset TESTENV_CLEANED
TESTENV_NO_ENGINE=1
testenv_init >/dev/null || exit 1
print -r -- "$T"
print -r -- "$TS"
print -r -- "${{TESTID:-}}"
print -r -- "$ENGINE"
"""],
    capture_output=True, text=True, env=env,
)
if init.returncode != 0:
    sys.stderr.write(init.stderr or init.stdout or "init failed\n")
    sys.exit(2)
lines = [ln for ln in init.stdout.splitlines() if ln]
T, TS, TESTID, ENGINE = lines[-4], lines[-3], lines[-2], lines[-1]
os.makedirs(os.path.join(T, "helpers"), exist_ok=True)
subprocess.check_call(["cp", busy, os.path.join(T, "busy-standin")])
subprocess.check_call(["cp", busy, os.path.join(T, "helpers", "grandchild-standin")])
subprocess.Popen([os.path.join(T, "busy-standin")])
gc = os.path.join(T, "helpers", "grandchild-standin")
if os.fork() == 0:
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    os.chdir("/")
    os.execv(gc, [gc])
time.sleep(0.5)

def on_term(signum, frame):
    r = subprocess.call(["zsh", "-c", f"""
source '{repo}/tests/lib/testenv.sh'
T={T!r}
TS={TS!r}
TESTID={TESTID!r}
ENGINE={ENGINE!r}
unset TESTENV_CLEANED
testenv_cleanup
"""])
    raise SystemExit(143 if r == 0 else r)

# Arm handler BEFORE announcing ready — otherwise the parent can SIGTERM us with the default disposition.
signal.signal(signal.SIGTERM, on_term)
with open(tb, "w") as f:
    f.write(T + "\n")
time.sleep(120)
PY
python3 "$BUILD/phase_b.py" "$TESTENV_REPO" "$BUILD" "$T_B_FILE" >/dev/null 2>"$BUILD/phase_b.err" &
SUB=$!
poll 30 test -s "$T_B_FILE" || { print -r -- "phase_b.err: $(cat "$BUILD/phase_b.err" 2>/dev/null)"; fail "phase (b): child never wrote \$T"; }
T_B=$(cat "$T_B_FILE")
orphans_under "$T_B" | grep -q . || fail "phase (b): stand-ins not running before SIGTERM"
kill -TERM $SUB 2>/dev/null
phase_b_gone() { ! kill -0 $SUB 2>/dev/null; }
poll 20 phase_b_gone || { kill -KILL $SUB 2>/dev/null; fail "phase (b): helper still alive after SIGTERM"; }
wait $SUB 2>/dev/null
sleep 0.5
left_b=$(orphans_under "$T_B")
[[ -z "$left_b" ]] || fail "phase (b): orphans still under $T_B after SIGTERM: $left_b"
still_alive $CTRLPID || fail "phase (b): control process in $CTRL was killed"
print "ok: SIGTERM cleanup killed stand-ins under $T_B; control survived"

# --- control still alive; tear it down ourselves (exact pid — never a broad pgrep) ---
still_alive $CTRLPID || fail "control died unexpectedly"
kill -TERM $CTRLPID 2>/dev/null
sleep 0.5
kill -KILL $CTRLPID 2>/dev/null
wait $CTRLPID 2>/dev/null
rm -rf "$CTRL"
print "ok: control from a different cosmotest.* folder was never reaped by another run's cleanup"
print "PASS cleanup_orphans"
