#!/bin/zsh
# Repair lock: one repair per bottle; the kernel releases it when the holder dies; Wine processes started during a repair never
# inherit it (the lock file is opened O_CLOEXEC). A negative control first shows that this test does detect inheritance.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
held() { python3 -I -c "import fcntl,os,sys; fd=os.open(sys.argv[1], os.O_RDWR)
try: fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB); print('free')
except BlockingIOError: print('held')" "$1"; }

# Negative control: lock WITHOUT O_CLOEXEC, spawn a child, exit → the child keeps the lock. With O_CLOEXEC → free.
cat > "$T/inherit.c" <<'C'
#include <fcntl.h>
#include <spawn.h>
#include <sys/file.h>
extern char **environ;
int main(int argc, char **argv) {
    int fd = open(argv[1], O_CREAT | O_RDWR | (argc > 2 ? O_CLOEXEC : 0), 0644); flock(fd, LOCK_EX);
    pid_t p; char *a[] = { "/bin/sleep", "15", 0 }; posix_spawn(&p, "/bin/sleep", 0, 0, a, environ); return 0;
}
C
clang -o "$T/inherit" "$T/inherit.c" || fail "could not build the control"
"$T/inherit" "$T/ctl.lock"; [[ "$(held "$T/ctl.lock")" == held ]] || fail "control: an inherited descriptor did not keep the lock (test can't see inheritance)"
"$T/inherit" "$T/ctl2.lock" cloexec; [[ "$(held "$T/ctl2.lock")" == free ]] || fail "control: O_CLOEXEC did not prevent inheritance"
print "ok: control shows an inherited descriptor keeps an flock, and O_CLOEXEC prevents it"

tw_snapshot
ct --newbottle A >/dev/null 2>&1; [[ -d "$(tprefix A)/drive_c" ]] || fail "throwaway bottle not created"
LOCK="$(tprefix A)/.cosmo.lock"
(COSMO_TEST_HOLD_LOCK_SECS=120 sandbox-exec -p "$(tw_sandbox_profile)" env CFFIXED_USER_HOME="$TH" HOME="$TH" COSMO_TEST_HOME="$TH" "$T/CosmopolitanTest.app/Contents/MacOS/Cosmopolitan" --repair A > "$T/r1.log" 2>&1 &)
lock_ready() { [[ -f "$LOCK" && "$(held "$LOCK")" == held ]] && pgrep -f "ping -n" >/dev/null; }
poll 120 lock_ready || fail "first repair never took the lock with a Wine child running (waited 120 s)"; print "ok: first repair holds the lock with its Wine child running after ${POLL_TOOK} s"
app=$(pgrep -f "$T/CosmopolitanTest.app/Contents/MacOS/Cosmopolitan --repair A")
[[ -n "$app" && "$(held "$LOCK")" == held ]] || fail "first repair never took the lock"
out=$(ct --repair A 2>&1); [[ "$out" == *"another repair is already running"* ]] || fail "a second repair ran while the first held the lock: $out"
holders=$(lsof -t "$LOCK" 2>/dev/null | sort -u | tr '\n' ' '); [[ "$holders" == "$app " ]] || fail "lock file open in other processes too: $holders (app $app)"
kill -9 "$app"; lock_free() { [[ "$(held "$LOCK")" == free ]]; }; poll 120 lock_free; print "ok: lock free ${POLL_TOOK} s after kill -9"
[[ -n "$(tserverpid A)" ]] || fail "no Wine child alive after the kill (test needs one)"
[[ "$(held "$LOCK")" == free ]] || fail "lock still held after the app died: $(lsof "$LOCK" 2>/dev/null | tail -n +2)"
out=$(ct --repair A 2>&1); [[ "$out" == *"Repair done"* ]] || fail "repair after the holder died did not run: $(print -r -- "$out" | tail -2)"
tw_check || fail "your real data changed"
print "PASS repair_lock: second repair refused; after kill -9 the lock was free while bottle A's Wine child still ran"
