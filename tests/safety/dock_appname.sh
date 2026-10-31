#!/bin/zsh
# PR #37 (cosmos-engine-support): on Cosmos, syncDockAppNames writes Mac Driver › AppName via one wine reg import and
# records owner=dock-name in the registry ledger. Plant a COSMOS-BUILD.txt so engineHasDockPatches is true, then run on
# Wine 10 (plain testenv) — the registry path does not need a Cosmos-built engine.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot

# Pretend this throwaway engine has Dock patches 0029/0030 (read from COSMOS-BUILD.txt beside wswine.bundle).
defaults write "$TESTID" engine "$ENGINE"
print -r -- $'Cosmos local test stub\npatches:\n  0029-ntdll-dock-name-from-appname\n  0030-winemac-no-dock-icon-option\n' \
  > "$TS/engines/$ENGINE/COSMOS-BUILD.txt"
grep -q '0029-ntdll-dock-name-from-appname' "$TS/engines/$ENGINE/COSMOS-BUILD.txt" || fail "COSMOS-BUILD.txt stub missing 0029"
grep -q '0030-winemac-no-dock-icon-option' "$TS/engines/$ENGINE/COSMOS-BUILD.txt" || fail "COSMOS-BUILD.txt stub missing 0030"

ct --newbottle Q >/dev/null 2>&1
[[ -d "$(tprefix Q)/drive_c" ]] || fail "throwaway bottle Q not created"

# Steam game stand-in (same shape as steam_dock_addon).
S="$(tprefix Q)/drive_c/Program Files (x86)/Steam/steamapps"
mkdir -p "$S/common/FakeW"
cp "$(tprefix Q)/drive_c/windows/system32/notepad.exe" "$S/common/FakeW/fakew.exe"
printf '"AppState"\n{\n\t"appid"\t\t"9"\n\t"name"\t\t"Fake Witcher: Wild \u2014 Hunt"\n\t"installdir"\t\t"FakeW"\n\t"StateFlags"\t\t"4"\n}\n' > "$S/appmanifest_9.acf"

ct --status Q >/dev/null 2>&1
# wine reg import updates the live prefix; user.reg on disk is flushed when this bottle's wineserver exits.
twineserver Q -w 2>/dev/null

want=$'Fake Witcher: Wild \u2014 Hunt'
L="$(tprefix Q)/options/.registry-ledger.json"
# Wine may store the em dash as \x2014 in user.reg; accept either form.
appname_ok() {
  local ureg="$(tprefix Q)/user.reg"
  rg -q 'AppDefaults\\\\fakew\.exe\\\\Mac Driver' "$ureg" 2>/dev/null || return 1
  rg -q --fixed-strings "\"AppName\"=\"${want}\"" "$ureg" 2>/dev/null \
    || rg -q 'AppName"="Fake Witcher: Wild \\x2014 Hunt"' "$ureg" 2>/dev/null \
    || rg -q 'AppName"="Fake Witcher: Wild \x2014 Hunt"' "$ureg" 2>/dev/null
}
ledger_ok() {
  [[ -f "$L" ]] || return 1
  python3 -I -c '
import json,sys
want=sys.argv[1]
rows=json.load(open(sys.argv[2]))
ok=any(r.get("owner")=="dock-name" and r.get("exe")=="fakew.exe" and r.get("name")=="AppName" and r.get("value")==want for r in rows)
sys.exit(0 if ok else 1)
' "$want" "$L"
}
poll 30 ledger_ok || fail "ledger missing dock-name AppName for fakew.exe after scan (options=$(ls "$(tprefix Q)/options" 2>&1); dock-names=$(cat "$(tprefix Q)/options/dock-names.txt" 2>&1); ledger=$(cat "$L" 2>&1))"
appname_ok || fail "user.reg lacks AppName for fakew.exe (snippet: $(rg -n 'fakew|AppName' "$(tprefix Q)/user.reg" 2>&1 | head -30))"
print "ok: scan wrote Mac Driver AppName for fakew.exe; ledger owner=dock-name"

# Second scan must change nothing (same want → syncDockAppNames returns without rewriting).
before=$(shasum "$L" | awk '{print $1}')
before_reg=$(rg -n 'AppDefaults\\\\fakew\.exe\\\\Mac Driver' -A5 "$(tprefix Q)/user.reg" 2>/dev/null || true)
ct --status Q >/dev/null 2>&1
twineserver Q -w 2>/dev/null
after=$(shasum "$L" | awk '{print $1}')
after_reg=$(rg -n 'AppDefaults\\\\fakew\.exe\\\\Mac Driver' -A5 "$(tprefix Q)/user.reg" 2>/dev/null || true)
[[ "$before" == "$after" ]] || fail "second scan changed the ledger ($before → $after)"
[[ "$before_reg" == "$after_reg" ]] || fail "second scan changed AppName registry value"
print "ok: second scan left AppName and ledger unchanged"

tw_check
print "PASS dock_appname"
