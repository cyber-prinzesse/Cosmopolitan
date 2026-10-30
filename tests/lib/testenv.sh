#!/bin/zsh
# Shared test environment. Source it, then call testenv_init. Gives:
#   ct ARGS…        the test build (bundle id local.cosmopolitan.<id>.test, unique per throwaway home: macOS keeps preferences per user,
#                   not per HOME, so each environment gets its own domain, deleted at cleanup) with a throwaway home (HOME, CFFIXED_USER_HOME
#                   and COSMO_TEST_HOME all point at it, so the app's support folder, bottles and log live there)
#   tw_snapshot / tw_check   tripwire over YOUR real data: bottles folder, Cosmopolitan log, Steam bottle, running Steam and app
#                   (content hashes via tests/lib/tw.py; notes and failures name the changed files, and the keys for .reg files)
#   testenv_cleanup  kills every process whose executable/argv[0] is under this run's $T/, stops wineservers, removes $T
#                   (EXIT / INT / TERM — so fail(), Ctrl-C and timeouts cannot leave native stand-ins behind)
# Nothing here writes outside the throwaway folder. The engine and backends are APFS clones (no extra disk space).
# testenv_init proves the sandbox on your real files every time it runs (see below). Safe under set -u.

zmodload zsh/datetime   # EPOCHREALTIME, for timing every wait
TESTENV_REPO="${${(%):-%x}:A:h:h:h}"
REAL_HOME="$(dscl . -read /Users/$(id -un) NFSHomeDirectory | awk '{print $2}')"
REAL_SUPPORT="$REAL_HOME/Library/Application Support/Cosmopolitan"
REAL_LOG="$REAL_HOME/Library/Logs/Cosmopolitan.log"
ENGINE="${COSMO_ENGINE:-WS12WineSikarugir10.0_8}"   # COSMO_ENGINE_DIR: a trial engine folder outside your app data (copied in as $ENGINE)

testenv_init() {
  emulate -L zsh
  T="$(mktemp -d /private/tmp/cosmotest.XXXXXX)" || return 1
  TH="$T/home"; TS="$TH/Library/Application Support/Cosmopolitan"
  mkdir -p "$TS/engines" "$TH/Library/Logs"
  cp -cR "$TESTENV_REPO/build.noindex/Cosmopolitan.app" "$T/CosmopolitanTest.app"
  # Its own settings; never a cosmopolitan:// handler and no update checks (GUI screenshots run it as a normal app).
  TESTID="local.cosmopolitan.${${T:t}#cosmotest.}.test"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TESTID" -c "Set :CFBundleName CosmopolitanTest" -c "Delete :CFBundleURLTypes" -c "Set :SUEnableAutomaticChecks false" "$T/CosmopolitanTest.app/Contents/Info.plist"
  rm -rf "$T/CosmopolitanTest.app/Contents/Resources/Metadata.appintents"   # its intents never reach your Shortcuts
  codesign --force --deep --sign - "$T/CosmopolitanTest.app" 2>/dev/null
  if [[ -z "${TESTENV_NO_ENGINE:-}" ]]; then   # a --setup test wants an empty support folder
    if [[ -n "${COSMO_ENGINE_DIR:-}" ]]; then cp -cR "$COSMO_ENGINE_DIR" "$TS/engines/$ENGINE"; defaults write "$TESTID" engine "$ENGINE"; else cp -cR "$REAL_SUPPORT/engines/$ENGINE" "$TS/engines/" 2>/dev/null; fi
    cp -cR "$REAL_SUPPORT/engines/renderer" "$TS/engines/" 2>/dev/null
    [[ -d "$REAL_SUPPORT/engines/gstreamer" ]] && cp -cR "$REAL_SUPPORT/engines/gstreamer" "$TS/engines/"
    local bin="$TS/engines/$ENGINE/wswine.bundle/bin" f
    for f in "$bin"/*(N.); do [[ "$f:t" != wine ]] && cmp -s "$f" "$bin/wine" && rm -f "$f"; done   # loader copies named after your programs (exact copies of bin/wine)
    cp "$REAL_SUPPORT/terms-accepted.json" "$TS/" 2>/dev/null
    [[ -f "$REAL_SUPPORT/d3dmetal-license.json" ]] && cp "$REAL_SUPPORT/d3dmetal-license.json" "$TS/"
  fi
  mkdir -p "$TS/cache"; for f in "$TESTENV_REPO"/.cache/*(N.) "$REAL_SUPPORT"/cache/*(N.); do cp -c "$f" "$TS/cache/" 2>/dev/null; done   # pinned downloads (hash-checked on use)
  # Sandbox proof, at the start of every suite run: opening your real log, every bottle's user.reg and Homebrew's brew for writing is refused inside the
  # test sandbox (the probe appends zero bytes, so even a failed proof changes nothing), and the same probe works in the throwaway folder.
  local probe=() p; [[ -f "$REAL_LOG" ]] && probe+=("$REAL_LOG"); probe+=("$REAL_SUPPORT"/bottles/*/user.reg(N.)); [[ -f /opt/homebrew/bin/brew ]] && probe+=(/opt/homebrew/bin/brew)
  for p in $probe; do sandbox-exec -p "$(tw_sandbox_profile)" /bin/sh -c ': >> "$1"' sh "$p" 2>/dev/null && { print -u2 "FAIL: sandbox proof: a write to $p was allowed"; return 1; }; done
  sandbox-exec -p "$(tw_sandbox_profile)" /bin/sh -c ': >> "$1"' sh "$T/sandbox-probe" || { print -u2 "FAIL: sandbox proof: the probe can't write in the throwaway folder either"; return 1; }
  print -u2 "ok: sandbox proof: writes refused for ${#probe} real files (${(j:, :)${probe[@]#$REAL_HOME/}}), allowed in the throwaway folder"
  print "test env: $T"
  unset TESTENV_CLEANED
  # Do not trap EXIT here: in zsh an EXIT trap set inside a function runs when the function returns (and would delete $T
  # before the test starts). Callers arm cleanup with: eval "$(testenv_trap_cleanup)"
}
# Arm cleanup in the calling shell: eval "$(testenv_trap_cleanup)" after testenv_init.
# Must not run `trap … EXIT` (or define TRAPEXIT) inside this function — zsh would fire it when the
# function returns and delete $T before the test starts. INT/TERM: cleanup then SIGKILL this shell —
# zsh often ignores `exit` inside a signal trap while blocked in sleep (parent stayed alive after TERM).
testenv_trap_cleanup() {
  print -r -- "trap 'testenv_cleanup' EXIT; trap 'testenv_cleanup; trap - INT TERM; kill -KILL \$\$' INT; trap 'testenv_cleanup; trap - INT TERM; kill -KILL \$\$' TERM"
}

# Every test-build run is sandboxed: writes to your real Cosmopolitan folders, log and Sikarugir folder are impossible for it and for every
# Wine process it starts, so a change there during a test can only come from your own running Steam or app.
ct() { sandbox-exec -p "$(tw_sandbox_profile)" env CFFIXED_USER_HOME="$TH" HOME="$TH" COSMO_TEST_HOME="$TH" "$T/CosmopolitanTest.app/Contents/MacOS/Cosmopolitan" "$@"; }
tprefix() { print -r -- "$TS/bottles/$1"; }
# poll MAX_SECONDS CMD…: runs CMD every 0.5 s until it succeeds or MAX_SECONDS pass; POLL_TOOK = seconds it actually took.
# Its locals are prefixed: zsh scoping is dynamic, so a plain "t0" here would shadow a test's own t0 inside CMD.
poll() { local _poll_max=$1 _poll_t0=$EPOCHREALTIME; shift
  while ! "$@" >/dev/null 2>&1; do (( EPOCHREALTIME - _poll_t0 > _poll_max )) && { POLL_TOOK=$(printf '%.1f' $(( EPOCHREALTIME - _poll_t0 ))); return 1; }; sleep 0.5; done
  POLL_TOOK=$(printf '%.1f' $(( EPOCHREALTIME - _poll_t0 ))); }
# tlaunch BOTTLE EXE [MAX]: launches through the test build with --wait (it polls every 0.5 s, up to MAX, default 120 s) and returns its
# exit status: the program's own exit code, or 124 if it was still running at MAX. LAUNCH_CODE = that status, LAUNCH_TOOK = seconds,
# LAUNCH_LINE = the app's own line.
tlaunch() { local out; out=$(ct --launch "$1" "$2" --wait "${3:-120}" 2>&1); LAUNCH_CODE=$?
  LAUNCH_LINE=$(print -r -- "$out" | grep '^launch: ' | tail -1); LAUNCH_TOOK=$(print -r -- "$LAUNCH_LINE" | sed -n 's/.* after \([0-9.]*\) s.*/\1 s/p')
  return $LAUNCH_CODE; }
twine() {   # twine BOTTLE ARGS… — Wine in a throwaway prefix, msync like the app
  local b="$1"; shift
  sandbox-exec -p "$(tw_sandbox_profile)" env CFFIXED_USER_HOME="$TH" HOME="$TH" WINEPREFIX="$(tprefix "$b")" WINEMSYNC=1 WINEDEBUG=-all "$TS/engines/$ENGINE/wswine.bundle/bin/wine" "$@"
}
twineserver() { local b="$1"; shift; WINEPREFIX="$(tprefix "$b")" "$TS/engines/$ENGINE/wswine.bundle/bin/wineserver" "$@"; }

# ---- tripwire over the real data ----
_tw_state() {
  emulate -L zsh
  print "bottles: $(ls -1 "$REAL_SUPPORT/bottles" 2>/dev/null | tr '\n' ' ')"
  print "support-top: $(ls -1A "$REAL_SUPPORT" 2>/dev/null | tr '\n' ' ')"
  print "engines-bin: $(ls -1 "$REAL_SUPPORT/engines/$ENGINE/wswine.bundle/bin" 2>/dev/null | tr '\n' ' ')"
  for b in "$REAL_SUPPORT"/bottles/*(N/); do
    print "bottle $b:t: $(cd "$b" && find . -maxdepth 1 ! -name '*.reg' ! -name 'drive_c' ! -name 'dosdevices' ! -name '.update-timestamp' | sort | tr '\n' ' ')"
    for f in cosmopolitan.env cosmopolitan.apps; do [[ -f "$b/$f" ]] && print "  $f $(shasum -a 256 "$b/$f" | cut -c1-16)"; done
    [[ -d "$b/options" ]] && print "  options-settings $(cd "$b/options" && find . -type f -name '*.env' -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -c1-16)"
  done
  if [[ -f "$REAL_LOG" ]]; then print "log-inode: $(stat -f %i "$REAL_LOG")"; fi
  print "steam-pid: $(_tw_real_steam)"
  print "app-pid: $(pgrep -f "$TESTENV_REPO/build.noindex/Cosmopolitan.app/Contents/MacOS/Cosmopolitan\$" | head -1)"
}
# Cache markers your running Cosmopolitan app updates by itself (scan results, playtime, AVX counts, the registry ledger), one per file;
# and every key of your bottles' .reg files, flagged when Cosmopolitan owns it. Both are content hashes (tests/lib/tw.py).
_tw_markers() { [[ -d "$REAL_SUPPORT/bottles" ]] && python3 -I "$TESTENV_REPO/tests/lib/tw.py" markers "$REAL_SUPPORT/bottles"; }
_tw_regkeys() { [[ -d "$REAL_SUPPORT/bottles" ]] && python3 -I "$TESTENV_REPO/tests/lib/tw.py" regkeys "$REAL_SUPPORT/bottles"; }
# Lines "owned<TAB>file<TAB>[key]" (sorted by file) → "  file: [key], [key]"
_tw_keylist() { awk -F'\t' '$2 != f { if (f != "") print "  " f ": " ks; f = $2; ks = $3; next } { ks = ks ", " $3 } END { if (f != "") print "  " f ": " ks }'; }
tw_snapshot() {
  TW_STATE="$(_tw_state)"; TW_REGKEYS="$(_tw_regkeys)"; TW_MARKERS="$(_tw_markers)"
  TW_LOG_SIZE=$( [[ -f "$REAL_LOG" ]] && stat -f %z "$REAL_LOG" || print 0 )
  TW_LOG_HEAD=$( [[ -f "$REAL_LOG" ]] && head -c "$TW_LOG_SIZE" "$REAL_LOG" 2>/dev/null | shasum -a 256 | cut -c1-16 )
}
# tw_check: fails on any change to your data, with two lenient rules, each printed as a note naming the files (and keys):
#   cache markers changed while your Cosmopolitan app runs; registry keys changed while your Steam runs (the test is sandboxed, so it
#   can't have written them) — except keys Cosmopolitan owns (AppDefaults, DllOverrides, the ledger's keys), which always fail.
# Whether your own Cosmopolitan app or your Steam is running (TW_FAKE_APP / TW_FAKE_STEAM = 0/1 override them, for the rule test only).
# The everyday app may still live at <repo>/Cosmopolitan.app (updated in place by Sparkle); new builds are in build.noindex/.
_tw_app_running() { [[ -n "${TW_FAKE_APP:-}" ]] && { [[ "$TW_FAKE_APP" == 1 ]]; return; }; [[ -n "$(pgrep -f "$TESTENV_REPO/Cosmopolitan.app/Contents/MacOS/Cosmopolitan\$|$TESTENV_REPO/build.noindex/Cosmopolitan.app/Contents/MacOS/Cosmopolitan\$|/Applications/Cosmopolitan.app/Contents/MacOS/Cosmopolitan\$")" ]]; }
_tw_steam_running() { [[ -n "${TW_FAKE_STEAM:-}" ]] && { [[ "$TW_FAKE_STEAM" == 1 ]]; return; }; [[ -n "$(_tw_real_steam)" ]]; }
# Your Steam: the process whose program (the command line's first word) is Steam\steam.exe and whose working folder is inside your real
# bottles (Wine keeps it on the Windows current directory). Not a steamwebhelper that mentions steam.exe in its arguments, not a test's
# stand-in Steam in a throwaway bottle.
_tw_real_steam() { local p c; for p in $(pgrep -f 'steam\.exe'); do c=$(ps -o command= -p $p 2>/dev/null); [[ "${c%% -*}" == *'\Steam\steam.exe' ]] || continue
  [[ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "$REAL_SUPPORT/bottles/"* ]] && print $p; done | sort -n | head -1; }
tw_check() {
  emulate -L zsh
  local ok=1 now="$(_tw_state)" keys="$(_tw_regkeys)"
  [[ "$now" == "$TW_STATE" ]] || { ok=0; print "TRIPWIRE: real data changed:"; diff <(print -r -- "$TW_STATE") <(print -r -- "$now") | sed 's/^/  /'; }
  if [[ -f "$REAL_LOG" ]]; then
    local size=$(stat -f %z "$REAL_LOG") head=$(head -c "$TW_LOG_SIZE" "$REAL_LOG" 2>/dev/null | shasum -a 256 | cut -c1-16)
    (( size >= TW_LOG_SIZE )) && [[ "$head" == "$TW_LOG_HEAD" ]] || { ok=0; print "TRIPWIRE: your Cosmopolitan.log was truncated or rewritten"; }
  fi
  local markers="$(_tw_markers)"
  if [[ "$markers" != "$TW_MARKERS" ]]; then
    local files="$(diff <(print -r -- "$TW_MARKERS") <(print -r -- "$markers") | sed -n 's/^[<>] [0-9a-z]*  //p' | sort -u | sed 's/^/  /')"
    if _tw_app_running; then
      print "note: cache markers in your bottles' options folders changed while your Cosmopolitan app was running (it updates them itself; the test build can't reach them):"
    else ok=0; print "TRIPWIRE: cache markers in your bottles' options folders changed with no Cosmopolitan app running:"; fi
    print -r -- "$files"
  fi
  if [[ "$keys" != "$TW_REGKEYS" ]]; then   # changed keys (in $REAL_SUPPORT/bottles), each once, owned first if its flag differs
    local changed="$(diff <(print -r -- "$TW_REGKEYS") <(print -r -- "$keys") | sed -n 's/^[<>] //p' | awk -F'\t' '{print $4 "\t" $1 "\t" $2}' | sort -t$'\t' -k2,2 -k3,3 -k1,1r | awk -F'\t' '!seen[$2 FS $3]++')"
    local owned="$(print -r -- "$changed" | grep '^1')" other="$(print -r -- "$changed" | grep '^0')"
    if [[ -n "$owned" ]]; then ok=0; print "TRIPWIRE: registry keys Cosmopolitan owns changed (this fails even while Steam runs):"; print -r -- "$owned" | _tw_keylist; fi
    if [[ -n "$other" ]]; then
      if _tw_steam_running; then   # ct and twine are sandboxed, so the test couldn't have written them
        print "note: registry keys changed while your Steam was running; the test could not write there (sandboxed), so Steam's own Wine server wrote them:"
      else ok=0; print "TRIPWIRE: registry keys of your bottles changed (Steam not running):"; fi
      print -r -- "$other" | _tw_keylist
    fi
  fi
  (( ok )) && print "tripwire: your bottles, log, Steam and app are untouched"
  (( ok ))
}
# Sandbox profile that makes writes to your real Cosmopolitan data impossible for the test and everything it starts.
tw_sandbox_profile() {
  print "(version 1)(allow default)(deny file-write* (subpath \"$REAL_SUPPORT\") (literal \"$REAL_LOG\") (subpath \"$REAL_HOME/Applications/Cosmopolitan Apps\") (subpath \"$REAL_HOME/Library/Application Support/Sikarugir\") (subpath \"/opt/homebrew\"))"
}

# True iff $1 is exactly this run's throwaway root (mktemp /private/tmp/cosmotest.XXXXXX — 6 alnum chars).
_testenv_t_ok() {
  emulate -L zsh
  [[ -n "${1:-}" && "$1" =~ '^/private/tmp/cosmotest\.[A-Za-z0-9]{6}$' ]]
}
# pgrep -f pattern for processes under $1. Pure zsh (suffix is alphanumeric — no sed/python escape).
# Prints the pattern and returns 0, or prints nothing and returns 1 if $1 is unsafe.
_testenv_kill_pattern() {
  emulate -L zsh
  local t="${1:-}"
  _testenv_t_ok "$t" || return 1
  local pat="^/private/tmp/cosmotest\\.${t:t:e}/"
  [[ -n "$pat" && "$pat" == '^/private/tmp/cosmotest\.'* ]] || return 1
  print -r -- "$pat"
  return 0
}
# True if $1 is this shell, its parent, or an ancestor (never signal those).
_testenv_is_self_or_ancestor() {
  emulate -L zsh
  local want=$1 cur=$$
  while [[ -n "$cur" && "$cur" -gt 0 ]]; do
    [[ "$cur" == "$want" ]] && return 0
    [[ "$cur" == 1 ]] && return 1
    cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
    [[ -z "$cur" ]] && return 1
  done
  return 1
}
# PIDs whose command line starts with $1/ (this throwaway only). Empty on any bad input — never a broad match.
# Re-checks each candidate with ps before accepting. Does not signal.
_testenv_pids_under_T() {
  emulate -L zsh
  local t="${1:-}" pat p cmd puid uid
  local -a out=()
  pat=$(_testenv_kill_pattern "$t") || {
    print -u2 "cleanup: refusing to kill (bad pattern)"
    return 1
  }
  uid=$(id -u)
  for p in $(pgrep -f "$pat" 2>/dev/null); do
    [[ "$p" == <-> ]] || continue
    _testenv_is_self_or_ancestor "$p" && continue
    cmd=$(ps -o command= -p "$p" 2>/dev/null) || continue
    [[ "$cmd" == "$t/"* ]] || continue
    puid=$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ')
    [[ "$puid" == "$uid" ]] || continue
    out+=("$p")
  done
  (( ${#out} )) && print -r -- "${out[@]}"
  return 0
}
# Signal only after a fresh ps check that the command still starts with $t/.
_testenv_kill_checked() {
  emulate -L zsh
  local sig=$1 p=$2 t=$3 cmd puid
  [[ "$p" == <-> && -n "$t" ]] || return 1
  _testenv_is_self_or_ancestor "$p" && return 1
  cmd=$(ps -o command= -p "$p" 2>/dev/null) || return 1
  [[ "$cmd" == "$t/"* ]] || return 1
  puid=$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ')
  [[ "$puid" == "$(id -u)" ]] || return 1
  kill "-$sig" "$p" 2>/dev/null
}
testenv_cleanup() {
  emulate -L zsh
  [[ -n "${T:-}" ]] || return 0
  [[ -z "${TESTENV_CLEANED:-}" ]] || return 0
  TESTENV_CLEANED=1
  [[ -n "${TESTID:-}" ]] && defaults delete "$TESTID" >/dev/null 2>&1   # the test build's own preferences domain, never your app's
  # Native stand-ins + test app live under $T/; wineserver -k never reaches them. Kill only after strict path checks.
  local p
  local -a pids=()
  if _testenv_t_ok "$T" && _testenv_kill_pattern "$T" >/dev/null; then
    pids=($(_testenv_pids_under_T "$T" 2>/dev/null))
    for p in $pids; do _testenv_kill_checked TERM "$p" "$T"; done
    if (( ${#pids} )); then
      sleep 2
      pids=($(_testenv_pids_under_T "$T" 2>/dev/null))
      for p in $pids; do _testenv_kill_checked KILL "$p" "$T"; done
    fi
  else
    print -u2 "cleanup: refusing to kill (bad pattern)"
  fi
  local ws="$TS/engines/$ENGINE/wswine.bundle/bin/wineserver" b
  [[ -x "$ws" ]] || ws=""
  if [[ -n "$ws" && -n "${TS:-}" ]]; then
    for b in "$TS"/bottles/*(N/); do WINEPREFIX="$b" "$ws" -k 2>/dev/null; done
    for b in "$TS"/bottles/*(N/); do WINEPREFIX="$b" perl -e 'alarm 30; exec @ARGV' -- "$ws" -w 2>/dev/null; done   # gone before the folder is
  fi
  _testenv_t_ok "$T" && rm -rf "$T"
}
# pid of the wineserver serving a throwaway prefix (it holds /tmp/.wine-<uid>/server-<dev>-<ino>/lock), empty if none
tserverpid() { local p="$(tprefix "$1")"; [[ -d "$p" ]] || return 0; lsof -t "$(printf '/tmp/.wine-%d/server-%x-%x/lock' $(id -u) $(stat -f '%d %i' "$p"))" 2>/dev/null | head -1; }
# Builds the stress test programs into a throwaway bottle (C:\StressTest), with the mingw compilers and the bottle's own Wine Mono.
stress_build() { HOME="$TH" "$TESTENV_REPO/tests/stress/build.sh" "$1" >/dev/null 2>&1 && [[ -f "$(tprefix "$1")/drive_c/StressTest/stress-d3d11-64.exe" ]]; }
