#!/bin/zsh
# Item 26: a snapshot is a clonefile copy of the whole bottle (APFS private size 0: every block shared with the bottle until it changes),
# taken before Repair, a driver switch, a registry sweep and a Windows-version change. The newest 3 are kept, for 3 days, and another bottle's are
# never touched (not even "S-2" next to "S"). Disk use counts what only the snapshots hold. Rollback restores the bottle, keeps the state
# before it as a snapshot, and stops only that bottle's programs (another bottle's Wine and a Mac process named *.exe keep running).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
clang -O2 -x c -o "$T/privsize" - <<'C' || fail "could not build the private-size probe"
#include <sys/attr.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
int main(int c, char **v) {   /* APFS private size: the bytes of a file no clone shares */
    struct attrlist al = {0}; al.bitmapcount = ATTR_BIT_MAP_COUNT; al.commonattr = ATTR_CMN_RETURNED_ATTRS; al.forkattr = ATTR_CMNEXT_PRIVATESIZE;
    struct __attribute__((packed)) { uint32_t len; attribute_set_t ret; off_t priv; } b;
    if (c < 2 || getattrlist(v[1], &al, &b, sizeof b, FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW) || !(b.ret.forkattr & ATTR_CMNEXT_PRIVATESIZE)) { puts("-1"); return 1; }
    printf("%lld\n", (long long)b.priv); return 0;
}
C
ct --newbottle S >/dev/null 2>&1; ct --newbottle S-2 >/dev/null 2>&1
[[ -d "$(tprefix S)/drive_c" && -d "$(tprefix S-2)/drive_c" ]] || fail "throwaway bottles not created"
snaps() { emulate -L zsh; print -l "$TS"/bottles/.auto-$1-<->-<->(N/On:t); }   # exact names, newest first
newest() { snaps $1 | head -1; }
reason() { cat "$TS/bottles/$(newest $1)/.snapshot-reason" 2>/dev/null; }
use() { ct --snapshots $1 2>&1 | sed -n 's/^disk held only by snapshots: \([0-9]*\) bytes/\1/p'; }
expect_new() {   # expect_new WHAT REASON-PATTERN: a new newest snapshot of S with that reason, and never more than 3
  local was=$1 what=$2 pat=$3 now=$(newest S) r=$(reason S)
  [[ "$now" != "$was" && "$r" == ${~pat} ]] || fail "$what: newest snapshot is '$now' ('$r'), expected a new one with '$pat'"
  (( $(snaps S | grep -c .) <= 3 )) || fail "$what: more than 3 snapshots: $(snaps S | tr '\n' ' ')"
  print -r -- "ok: $what took snapshot $now first (\"$r\"); S has $(snaps S | grep -c .) snapshots"
}

# 1. A clone, not a copy; disk use follows what diverges.
ct --snapshot S-2 "the other bottle's own" >/dev/null 2>&1; theirs=$(newest S-2); [[ -n "$theirs" ]] || fail "no snapshot of S-2"
dd if=/dev/urandom of="$(tprefix S)/drive_c/big.bin" bs=1m count=64 2>/dev/null
ct --snapshot S manual >/dev/null 2>&1; s1=$(newest S); [[ -n "$s1" && "$(reason S)" == manual ]] || fail "the manual snapshot is missing"
p=$("$T/privsize" "$TS/bottles/$s1/drive_c/big.bin"); u=$(use S)
[[ "$p" == 0 ]] || fail "the snapshot's 64 MB file holds $p bytes of its own: a copy, not a clone"
(( u < 1048576 )) || fail "disk use right after the snapshot: $u bytes"
print "ok: $s1 is a clone: its 64 MB file shares every block with the bottle (private size 0); disk use $u bytes"
dd if=/dev/urandom of="$(tprefix S)/drive_c/big.bin" bs=1m count=64 conv=notrunc 2>/dev/null
p=$("$T/privsize" "$TS/bottles/$s1/drive_c/big.bin"); u=$(use S)
(( p == 67108864 && u >= 67108864 )) || fail "after the bottle's file was rewritten: snapshot private size $p, disk use $u"
print "ok: once the bottle's file was rewritten the snapshot alone holds the old 64 MB (private size $p); disk use shows $u bytes"

# 2. Snapshots before Repair, a Windows-version change, a registry sweep and a driver switch; never more than 3; S-2's untouched.
stress_build S || fail "could not build the stress programs into S"
was=$(newest S); ct --repair S >/dev/null 2>&1; expect_new "$was" "Repair" "before Repair"
DD="$(tprefix S)/drive_c/StressTest/stress-ddraw-32.exe"
was=$(newest S); tlaunch S "$DD"; expect_new "$was" "a launch that sets a Windows version" "before Windows version change: stress-ddraw-32.exe default → win98"
was=$(newest S); tlaunch S "$DD"; [[ "$(newest S)" == "$was" ]] || fail "a launch with the same Windows version took another snapshot ($(reason S))"
print "ok: launching it again with the same Windows version took no snapshot"
mv "$DD" "$DD.gone"; was=$(newest S); out=$(ct --sweep-registry S 2>&1)
[[ "$out" == *"S: removed"* ]] || fail "the registry sweep removed nothing: $(print -r -- "$out" | tail -2)"
expect_new "$was" "the registry sweep" "before registry sweep"
was=$(newest S); ct --bisect S "$(tprefix S)/drive_c/StressTest/stress-d3d11-64.exe" >/dev/null 2>&1
grep -q '^DRIVERS=' "$(tprefix S)/options/stress-d3d11-64.exe.env" 2>/dev/null || fail "bisect saved no driver set"
expect_new "$was" "a driver switch (bisect)" "before driver switch: * → *"
[[ -d "$TS/bottles/$theirs" && "$(snaps S-2)" == "$theirs" ]] || fail "S-2's snapshot was touched: $(snaps S-2 | tr '\n' ' ')"
print "ok: S kept its newest 3 ($(snaps S | tr '\n' ' ')); S-2's own snapshot $theirs untouched"
keep=$(snaps S | tr '\n' ' '); for o in $(date -v-1d +%Y%m%d-%H%M%S) $(date -v-1d -v-1S +%Y%m%d-%H%M%S); do cp -cR "$(tprefix S)" "$TS/bottles/.auto-S-$o"; done
ct --cleanup >/dev/null 2>&1   # the daily housekeeping: it used to keep the newest 2 of all bottles together
[[ "$(snaps S | tr '\n' ' ')" == "$keep" && "$(snaps S-2)" == "$theirs" ]] || fail "daily cleanup: S has $(snaps S | tr '\n' ' '), S-2 has $(snaps S-2)"
print "ok: daily cleanup removed S's two planted older snapshots, kept S's newest 3 and S-2's own"

# 3. Rollback: restores the bottle, keeps the state before, stops only this bottle's programs.
print "state A" > "$(tprefix S)/drive_c/marker.txt"; ct --snapshot S "rollback target" >/dev/null 2>&1; tgt=$(newest S)
[[ "$(reason S)" == "rollback target" ]] || fail "no rollback target snapshot"
print "state B" > "$(tprefix S)/drive_c/marker.txt"
(twine S notepad >/dev/null 2>&1 &); (twine S-2 notepad >/dev/null 2>&1 &)
perl -e 'sleep 600' decoy.exe >/dev/null 2>&1 & decoy=$!
trap 'kill $decoy 2>/dev/null; testenv_cleanup' EXIT
both_up() { [[ -n "$(tserverpid S)" && -n "$(tserverpid S-2)" ]]; }
poll 120 both_up || fail "the bottles' Wine servers did not start"; mine=$(tserverpid S) other=$(tserverpid S-2)
ct --rollback S "${tgt#.auto-S-}" > "$T/rb.out" 2>&1
[[ "$(<"$(tprefix S)/drive_c/marker.txt")" == "state A" ]] || fail "rollback did not restore the bottle: $(tail -2 "$T/rb.out")"
before=$(newest S); [[ "$(reason S)" == "state before rollback" && "$(<"$TS/bottles/$before/drive_c/marker.txt")" == "state B" ]] || fail "the state before the rollback was not kept ($before: $(reason S))"
s_gone() { ! kill -0 "$mine" 2>/dev/null; }; poll 30 s_gone || fail "S's own Wine server ($mine) was not stopped"   # by pid: S is a new folder now
kill -0 "$other" 2>/dev/null || fail "S-2's Wine server was stopped by S's rollback"
kill -0 "$decoy" 2>/dev/null || fail "a Mac process with .exe in its command line was killed"
(( $(snaps S | grep -c .) <= 3 )) || fail "more than 3 snapshots after the rollback"
print "ok: rollback to $tgt restored the bottle (state A); the state before is snapshot $before (state B); only S's programs stopped"
print "  log: $(grep -m1 'Rolled back' "$T/rb.out")"
leftover=("$TS"/bottles/.deleting-*(N)); print "  pruned snapshots still being deleted in the background: ${#leftover}"
kill "$decoy" 2>/dev/null

# 4. Expiry: a snapshot older than 3 days goes at startup whatever the count (S-2 has only its own); the age is the stamp in the name.
old=.auto-S-2-$(date -v-4d +%Y%m%d-%H%M%S) recent=.auto-S-2-$(date -v-2d +%Y%m%d-%H%M%S)
for n in $old $recent; do cp -cR "$(tprefix S-2)" "$TS/bottles/$n"; done
ct --snapshots S-2 >/dev/null 2>&1
[[ ! -e "$TS/bottles/$old" && -d "$TS/bottles/$recent" && -d "$TS/bottles/$theirs" ]] || fail "expiry: S-2 has $(snaps S-2 | tr '\n' ' ')"
print "ok: the 4-day-old snapshot $old expired at startup; the 2-day-old one and S-2's own stay"
tw_check || fail "your real data changed"
print "PASS snapshots"
