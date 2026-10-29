#!/bin/zsh
# Rosetta fault-loop watchdog: a stand-in under Rosetta installs a SIGSEGV handler that returns without fixing the fault, then
# reads address 0x14 — Wine's hang signature without a GPU. The detector must SIGKILL it within ~30 s and leave a crash record.
# A busy x86_64 loop (no faults) must NOT be flagged.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle F >/dev/null 2>&1; [[ -d "$(tprefix F)/drive_c" ]] || fail "throwaway bottle not created"

# Faulting stand-in: Rosetta's exception server spins (same signature as D3DMetal's foreign-thread hang).
print '#include <signal.h>
#include <stdint.h>
static void h(int s, siginfo_t *i, void *c) { (void)s; (void)i; (void)c; }
int main(void) {
  struct sigaction sa; sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, 0);
  return *(volatile int *)(uintptr_t)0x14;
}' > "$T/fault.c"
clang -arch x86_64 -O0 -o "$T/fault-standin" "$T/fault.c" || fail "could not build the faulting stand-in (need Rosetta / x86_64 clang)"
# Busy control: burns CPU under Rosetta but never faults — exception server stays near idle.
print 'int main(void){ for(;;){} }' > "$T/busy.c"
clang -arch x86_64 -O0 -o "$T/busy-standin" "$T/busy.c" || fail "could not build the busy stand-in"

# --- Detect the fault loop ---
"$T/fault-standin" &
FPID=$!
sleep 1
kill -0 "$FPID" 2>/dev/null || fail "faulting stand-in exited before the watch started"
t0=$EPOCHREALTIME
out=$(ct --faultloop "$FPID" 35 2>&1) || true
took=$(printf '%.1f' $((EPOCHREALTIME - t0)))
print -r -- "$out" | grep -q "faultloop: detected and stopped pid $FPID" || fail "not detected: $(print -r -- "$out" | tail -5)"
kill -0 "$FPID" 2>/dev/null && { kill -9 "$FPID" 2>/dev/null; fail "stand-in still alive after detect ($took s)" }
print -r -- "ok: fault loop detected and killed in ${took}s"
rec=$(ls "$TS/crash-reports/" 2>/dev/null | grep '^FaultLoopStandin ' | tail -1)
[[ -n "$rec" ]] || fail "no crash record: $(ls "$TS/crash-reports/" 2>/dev/null | tr '\n' ' ')"
grep -q "froze in a crash loop inside the graphics driver: stopped it" "$TS/crash-reports/$rec" || fail "headline missing: $(head -3 "$TS/crash-reports/$rec")"
print "ok: crash record '$rec' with the fault-loop headline"

# --- Busy process must not be flagged ---
rm -f "$TS/crash-reports/"FaultLoopStandin*
"$T/busy-standin" &
BPID=$!
sleep 1
out=$(ct --faultloop "$BPID" 25 2>&1) || true
print -r -- "$out" | grep -q "faultloop: pid $BPID still running after 25 s (not flagged)" || fail "busy process was flagged or exited early: $(print -r -- "$out" | tail -5)"
kill -0 "$BPID" 2>/dev/null || fail "busy stand-in died during the watch"
kill -9 "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
ls "$TS/crash-reports/" 2>/dev/null | grep -q '^FaultLoopStandin ' && fail "busy process left a fault-loop crash record"
print "ok: busy x86_64 loop (no faults) was not flagged"

tw_check || fail "your real data changed"
print "PASS fault_loop"
