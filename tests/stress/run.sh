#!/bin/zsh
# Driver stress suite, isolated: the test build with a throwaway home; one golden throwaway bottle gets the test programs, and every test
# runs in its own fresh APFS clone of it (clean prefix, registry and display state per test). Prints each launch-check plan and result.
# Exit 1 unless every test wrote an OK line. Order: default, or ORDER=reverse / ORDER=random (seed printed) to prove order independence.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
tw_snapshot
ct --newbottle G >/dev/null 2>&1 && stress_build G || { print "could not create the golden bottle"; exit 1; }
exes=("$(tprefix G)"/drive_c/StressTest/stress-*.exe(N:t))
case "$ORDER" in reverse) exes=(${(Oa)exes});; random) SEED=${SEED:-$RANDOM}; print "random order, seed $SEED"; exes=($(print -l $exes | awk -v s=$SEED 'BEGIN{srand(s)} {print rand() "\t" $0}' | sort | cut -f2-));; esac
: > "$T/results.txt"; n=0
for e in $exes; do
  b="T$((n++))"; cp -cR "$(tprefix G)" "$(tprefix $b)"; : > "$(tprefix $b)/drive_c/StressTest/results.txt"
  ct --check $b "$(tprefix $b)/drive_c/StressTest/$e" 2>/dev/null | head -1 | sed -e 's/; not installed through a store — run only if you trust where it came from//' -e 's/; AVX scan pending//'
  tlaunch $b "$(tprefix $b)/drive_c/StressTest/$e"; print "    exit $LAUNCH_CODE after $LAUNCH_TOOK${${(M)LAUNCH_CODE:#124}:+ (124: still running at the 120 s limit, left running)}"
  r=$(cat "$(tprefix $b)/drive_c/StressTest/results.txt"); print -r -- "${r:-${e%.exe}: no result line}" >> "$T/results.txt"
  twineserver $b -k 2>/dev/null; rm -rf "$(tprefix $b)"
done
print; cat "$T/results.txt"
ok=$(grep -c ' OK ' "$T/results.txt"); print "$ok of $n passed (each in its own fresh prefix)"
tw_check || exit 1
(( ok == n ))
