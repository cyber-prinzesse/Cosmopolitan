#!/bin/zsh
# Steam's window loop (2026-10-28): steamwebhelper died and Steam started it again every 13-21 s, so the window kept reopening. Steam logs
# each start in logs/webhelper.txt; 3 within 2 minutes is a loop. A throwaway bottle gets a webhelper.txt written the way Steam writes it:
# a normal session (a start 10 min ago plus 2 recent ones: start and sign-in) says nothing; 4 starts within a minute are reported once, with
# the memory state, and leave a crash record carrying webhelper.txt's tail. Nothing runs in Wine: the check only reads the log.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
W="$(tprefix L)/drive_c/Program Files (x86)/Steam/logs/webhelper.txt"; mkdir -p "${W:h}"
start() { print -r -- "[$(date -v-${1}S '+%Y-%m-%d %H:%M:%S')] Startup - webhelper launched pid: $2 commandline: \"C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64\\steamwebhelper.exe\" -startcount=$3"
          print -r -- "[$(date -v-${1}S '+%Y-%m-%d %H:%M:%S')] Browser - launching child process with: steamwebhelper.exe --type=renderer"; }
{ start 600 308 0; start 70 1532 1; start 50 2092 1; } > "$W"
out=$(ct --steamloop L 2>&1)
[[ "$out" != *"window restarted"* ]] || fail "a normal start and sign-in were called a loop: $(print -r -- "$out" | grep 'window restarted')"
ls "$TS/crash-reports/" 2>/dev/null | grep -q '^Steam ' && fail "a normal session left a crash record"
print "ok: a normal session (one start 10 min ago, start + sign-in now) is no loop"
{ start 600 308 0; start 55 1532 1; start 35 2092 2; start 14 2864 3; start 1 636 4; } > "$W"
out=$(ct --steamloop L 2>&1)
line=$(print -r -- "$out" | grep "Steam's window restarted 4 times in 2 min (L)") || fail "the loop wasn't reported: $(print -r -- "$out" | tail -3)"
[[ "$line" == *"Free memory "*"%, swap "*" MB"* ]] || fail "the warning lacks the memory state: $line"
print -r -- "ok: reported: ${line:0:150}…"
rec=$(ls "$TS/crash-reports/" 2>/dev/null | grep '^Steam ' | tail -1); [[ -n "$rec" ]] || fail "no crash record for the loop"
R="$TS/crash-reports/$rec"
grep -q "^Steam's window restarted 4 times in 2 min at " "$R" && grep -q "^Last lines of Steam's logs/webhelper.txt:" "$R" && grep -q 'pid: 636 ' "$R" && grep -q '^Drivers: ' "$R" \
  || fail "the record lacks a part: $(head -8 "$R")"
print "ok: crash record '$rec' with webhelper.txt's tail, for the bug report"
# Deliberate Exit: bootstrap_log shows Shutdown with no newer Startup — webhelper noise during quit must not count as a loop
# (and must not offer "Restart Steam", which would bring Steam back after the user closed it).
B="$(tprefix L)/drive_c/Program Files (x86)/Steam/logs/bootstrap_log.txt"
print -r -- "[$(date -v-5S '+%Y-%m-%d %H:%M:%S')] Startup - Steam Client launched with: \"C:\\Program Files (x86)\\Steam\\steam.exe\"" > "$B"
print -r -- "[$(date -v-2S '+%Y-%m-%d %H:%M:%S')] Shutdown" >> "$B"
{ start 55 1532 1; start 35 2092 2; start 14 2864 3; start 1 636 4; } > "$W"
rm -rf "$TS/crash-reports"
out=$(ct --steamloop L 2>&1)
[[ "$out" != *"window restarted"* ]] || fail "a deliberate Shutdown was treated as a window loop: $(print -r -- "$out" | grep 'window restarted')"
ls "$TS/crash-reports/" 2>/dev/null | grep -q '^Steam ' && fail "a deliberate quit left a crash record"
print "ok: bootstrap Shutdown (no newer Startup) is not a window loop"
tw_check || fail "your real data changed"
print "PASS steam_loop"
