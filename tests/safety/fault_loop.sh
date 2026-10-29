#!/bin/zsh
# Fault-loop watchdog: a SIGSEGV handler that returns into the same faulting load (Wine's foreign-thread hang without a GPU).
# Detector uses PROC_PIDTASKINFO faults/s and messages_sent/s (real hang: ~58k faults/s, ~582k msgs/s; healthy DX12: ~0 / ~3k).
# Controls: busy multi-thread x86 loop; write-watch handler that faults in short bursts with pauses (GC-style) plus busy threads.
# Launcher-exits-first: parent starts the faulting child and exits; child still detected.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle F >/dev/null 2>&1; [[ -d "$(tprefix F)/drive_c" ]] || fail "throwaway bottle not created"
STAND="$(tprefix F)/drive_c/Games/FaultLoopStandin"; mkdir -p "$STAND"

# Measure PROC_PIDTASKINFO rates for a pid over 1 s (same counters the detector uses).
cat > "$T/task_rates.c" <<'C'
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int c, char **v) {
  int pid = atoi(v[1]);
  struct proc_taskinfo a, b; memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &a, sizeof a) <= 0) return 1;
  sleep(1);
  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &b, sizeof b) <= 0) return 1;
  printf("%lld %lld\n", (long long)(b.pti_faults - a.pti_faults), (long long)(b.pti_messages_sent - a.pti_messages_sent));
}
C
clang -O2 -o "$T/task_rates" "$T/task_rates.c" || fail "could not build task_rates"

# Faulting stand-in: handler returns without fixing → same load retries (matches the real hang's fault/message storm).
cat > "$T/fault.c" <<'C'
#include <signal.h>
#include <stdint.h>
static void h(int s, siginfo_t *i, void *c) { (void)s; (void)i; (void)c; }
int main(void) {
  struct sigaction sa = {0}; sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, 0);
  for (;;) { *(volatile int *)(uintptr_t)0x14; }
}
C
clang -arch x86_64 -O0 -o "$T/fault-standin" "$T/fault.c" || fail "could not build the faulting stand-in (need Rosetta / x86_64 clang)"
cp "$T/fault-standin" "$STAND/FaultLoopStandin.exe"

# Busy multi-thread control: CPU only, no fault storm.
cat > "$T/busy.c" <<'C'
#include <pthread.h>
static void *b(void *a) { (void)a; volatile unsigned long long x = 0; for (;;) x++; return 0; }
int main(void) {
  pthread_t t[4]; for (int i = 0; i < 4; i++) pthread_create(&t[i], 0, b, 0);
  for (;;) {}
}
C
clang -arch x86_64 -O0 -pthread -o "$T/busy-standin" "$T/busy.c" || fail "could not build the busy stand-in"

# Write-watch + busy, GC-style bursts (~1 s) with long pauses — a 5 s sample stays under the hang thresholds.
cat > "$T/watchbusy.c" <<'C'
#include <signal.h>
#include <stdint.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
static unsigned char *page;
static volatile int burst;
static void h(int s, siginfo_t *i, void *c) {
  (void)s; (void)c;
  if (i && (unsigned char *)i->si_addr >= page && (unsigned char *)i->si_addr < page + 4096)
    mprotect(page, 4096, PROT_READ | PROT_WRITE);
}
static void *busy(void *a) { (void)a; volatile unsigned long long x = 0; for (;;) x++; return 0; }
static void *faulty(void *a) {
  (void)a;
  for (;;) {
    if (!burst) { usleep(50000); continue; }
    mprotect(page, 4096, PROT_READ); page[0] = 1;
  }
  return 0;
}
int main(void) {
  page = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  memset(page, 0, 4096);
  struct sigaction sa = {0}; sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO; sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, 0); sigaction(SIGBUS, &sa, 0);
  pthread_t t[4];
  for (int i = 0; i < 3; i++) pthread_create(&t[i], 0, busy, 0);
  pthread_create(&t[3], 0, faulty, 0);
  for (;;) { burst = 1; sleep(1); burst = 0; sleep(9); }   /* GC-style: short storm, long quiet */
}
C
clang -arch x86_64 -O0 -pthread -o "$T/watchbusy-standin" "$T/watchbusy.c" || fail "could not build the write-watch stand-in"

# Launcher: starts FaultLoopStandin.exe from the bottle folder, exits after 2 s.
cat > "$T/launcher.c" <<EOF
#include <unistd.h>
#include <stdlib.h>
int main(void) {
  if (chdir("$STAND") != 0) return 2;
  pid_t c = fork();
  if (c < 0) return 3;
  if (c == 0) { execl("./FaultLoopStandin.exe", "./FaultLoopStandin.exe", (char *)0); _exit(127); }
  sleep(2);
  return 0;
}
EOF
clang -O0 -o "$T/launcher-standin" "$T/launcher.c" || fail "could not build the launcher stand-in"

# --- Measure stand-in rates (must clear the detector thresholds) ---
"$T/fault-standin" &
MPID=$!
sleep 1
rates=$("$T/task_rates" "$MPID") || { kill -9 "$MPID" 2>/dev/null; fail "task_rates failed"; }
kill -9 "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null
faults=${rates%% *}; msgs=${rates##* }
print -r -- "stand-in rates: faults/s=$faults messages_sent/s=$msgs (need >= 20000 and >= 100000)"
(( faults >= 20000 && msgs >= 100000 )) || fail "stand-in too quiet for the hang signature: $rates"

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

# --- Busy multi-thread must not be flagged ---
rm -f "$TS/crash-reports/"FaultLoopStandin*(N)
"$T/busy-standin" &
BPID=$!
sleep 1
out=$(ct --faultloop "$BPID" 25 2>&1) || true
print -r -- "$out" | grep -q "faultloop: pid $BPID still running after 25 s (not flagged)" || fail "busy process was flagged or exited early: $(print -r -- "$out" | tail -5)"
kill -0 "$BPID" 2>/dev/null || fail "busy stand-in died during the watch"
kill -9 "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
ls "$TS/crash-reports/" 2>/dev/null | grep -q '^FaultLoopStandin ' && fail "busy process left a fault-loop crash record"
print "ok: busy multi-thread x86 loop was not flagged"

# --- Write-watch bursts + busy must not be flagged ---
rm -f "$TS/crash-reports/"FaultLoopStandin*(N)
"$T/watchbusy-standin" &
WPID=$!
sleep 1
kill -0 "$WPID" 2>/dev/null || fail "write-watch stand-in exited before the watch started"
out=$(ct --faultloop "$WPID" 25 2>&1) || true
print -r -- "$out" | grep -q "faultloop: pid $WPID still running after 25 s (not flagged)" || fail "write-watch bursts were flagged: $(print -r -- "$out" | tail -5)"
kill -0 "$WPID" 2>/dev/null || fail "write-watch stand-in died during the watch"
kill -9 "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
ls "$TS/crash-reports/" 2>/dev/null | grep -q '^FaultLoopStandin ' && fail "write-watch left a fault-loop crash record"
print "ok: write-watch bursts + busy threads were not flagged"

# --- Launcher exits first; game child must still be detected ---
rm -f "$TS/crash-reports/"FaultLoopStandin*(N)
"$T/launcher-standin" &
LPID=$!
sleep 0.5
child=
for _ in {1..20}; do
  child=$(pgrep -f 'FaultLoopStandin\.exe' | head -1)
  [[ -n "$child" ]] && break
  sleep 0.2
done
[[ -n "$child" ]] || fail "launcher did not start the faulting child"
t0=$EPOCHREALTIME
out=$(ct --faultloop "$LPID" 40 2>&1) || true
took=$(printf '%.1f' $((EPOCHREALTIME - t0)))
print -r -- "$out" | grep -q "faultloop: detected and stopped" || fail "launcher handoff not detected: $(print -r -- "$out" | tail -5)"
kill -0 "$child" 2>/dev/null && { kill -9 "$child" 2>/dev/null; fail "faulting child still alive after detect ($took s)" }
print -r -- "ok: launcher exited first; faulting child detected and killed in ${took}s"
rec=$(ls "$TS/crash-reports/" 2>/dev/null | grep '^FaultLoopStandin ' | tail -1)
[[ -n "$rec" ]] || fail "no crash record after launcher handoff"
print "ok: crash record after launcher handoff: $rec"

tw_check || fail "your real data changed"
print "PASS fault_loop"
