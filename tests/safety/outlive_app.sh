#!/bin/zsh
# P5 (docs/research/crossover-oracle-findings.md): a program Cosmopolitan started keeps running when the app ends, whether it exits,
# is terminated (SIGTERM) or force-quit (SIGKILL). The program's output goes into a pipe the app reads (Process.swift); once the app
# is gone its writes fail, and that must not end it (Wine ignores SIGPIPE). A stand-in prints twice a second on stdout and stderr.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
ct --newbottle Q >/dev/null 2>&1; P="$(tprefix Q)"; [[ -d "$P/drive_c" ]] || fail "throwaway bottle not created"
print '#include <stdio.h>\n#include <windows.h>\nint main(void) { for (int i = 0; i < 240; i++) { printf("tick %d\\n", i); fflush(stdout); fprintf(stderr, "err %d\\n", i); Sleep(500); } return 0; }' > "$T/ticker.c"
x86_64-w64-mingw32-gcc -O2 -s "$T/ticker.c" -o "$P/drive_c/ticker.exe" || fail "no ticker"
alive() { pgrep -f '^C:.ticker\.exe' >/dev/null; }
for how in exit TERM KILL; do
  if [[ $how == exit ]]; then
    ct --launch Q "$P/drive_c/ticker.exe" 4 >/dev/null 2>&1   # the app runs 4 s, then ends with the program still going
  else
    ct --launch Q "$P/drive_c/ticker.exe" 90 >/dev/null 2>&1 &
    poll 30 alive || fail "$how: the program didn't start"; sleep 3
    app=$(pgrep -f "CosmopolitanTest.app/Contents/MacOS/Cosmopolitan --launch Q"); [[ -n "$app" ]] || fail "$how: app process not found"
    kill -$how $app; wait 2>/dev/null
  fi
  sleep 5; alive || fail "the program ended when the app ended ($how)"
  print "ok: the app ended ($how); the program was still running 5 s later"
  twineserver Q -k; poll 30 eval '! alive'
done
tw_check || fail "your real data changed"
print "PASS outlive_app"
