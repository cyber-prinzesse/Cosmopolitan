#!/bin/zsh
# Steam's Play button uses LaunchOptions in userdata/*/config/localconfig.vdf. For CDPR games Cosmopolitan syncs
# --launcher-used-gl=GLES --disable-gpu --disable-gpu-compositing (+ user ARGS) so REDlauncher draws under Wine;
# Cosmopolitan's own Play still uses --launcher-skip via LaunchCheck. Stand-in: REDprelauncher layout.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot

GLES='--launcher-used-gl=GLES --disable-gpu --disable-gpu-compositing'
LEGACY='--launcher-skip -dx12'   # what 1.3.9 wrote for Witcher 3

ct --newbottle S >/dev/null 2>&1; [[ -d "$(tprefix S)/drive_c" ]] || fail "throwaway bottle not created"
ST="$(tprefix S)/drive_c/Program Files (x86)/Steam"
D="$ST/steamapps/common/The Witcher 3"; mkdir -p "$D/bin/x64_dx12" "$ST/steamapps"
print -r -- 'int main(void){return 0;}' > "$T/g.c"
x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$D/REDprelauncher.exe" && x86_64-w64-mingw32-gcc -O2 -s "$T/g.c" -o "$D/bin/x64_dx12/witcher3.exe" || fail "could not build stand-ins"
print -r -- '{ "revision": 3, "executables": [ { "description": "DirectX 12", "executable": { "directoryPath": "bin\\x64_dx12", "fileName": "witcher3.exe" } } ], "gameId": "witcher3", "platform": "steam", "fallback": "DirectX 12" }' > "$D/launcher-configuration.json"
printf '"AppState"\n{\n\t"appid"\t\t"292030"\n\t"name"\t\t"The Witcher 3"\n\t"StateFlags"\t\t"4"\n\t"installdir"\t\t"The Witcher 3"\n}\n' > "$ST/steamapps/appmanifest_292030.acf"

# Minimal localconfig.vdf: UserLocalConfigStore/Software/Valve/Steam/Apps/292030 without LaunchOptions (two accounts).
mkcfg() {
  local f="$1" extra="${2:-}"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<VDF
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"Apps"
				{
					"292030"
					{
						"LastPlayed"		"1000"
${extra}					}
				}
			}
		}
	}
	"system"
	{
		"EnableGameOverlay"		"0"
	}
}
VDF
}
mkcfg "$ST/userdata/111/config/localconfig.vdf"
mkcfg "$ST/userdata/222/config/localconfig.vdf"

opts() { python3 -I -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); m=re.search(r"\"LaunchOptions\"\s*\"([^\"]*)\"", t); print(m.group(1) if m else "")' "$1"; }
# LaunchOptions must be its own indented line inside the app block (after "{" or after the last key), never glued to "{" and with no blank line after it.
fmt_ok() {
  python3 -I -c '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\"292030\"\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}", t, re.S)
if not m: sys.exit(1)
body = m.group(1)
if body.startswith("\t") or body.startswith(" "): sys.exit(2)   # glued to "{"
lines = body.split("\n")
content = [ln for ln in lines[1:] if True]
lo = next((i for i, ln in enumerate(content) if re.match(r"^\t+\"LaunchOptions\"\t\t\"[^\"]*\"$", ln)), None)
if lo is None: sys.exit(3)
if lo + 1 < len(content) and content[lo + 1] == "": sys.exit(4)   # blank line after LaunchOptions
print("ok")
' "$1"
}

# 1. Sync while Steam is down → CDPR GLES flags (not --launcher-skip); Cosmo Play still skips via LaunchCheck (red_launcher.sh).
out=$(ct --tunesteam S 2>&1)
o1=$(opts "$ST/userdata/111/config/localconfig.vdf"); o2=$(opts "$ST/userdata/222/config/localconfig.vdf")
[[ "$o1" == "$GLES" && "$o2" == "$GLES" ]] || fail "after tunesteam: 111='$o1' 222='$o2' (want GLES)"
[[ -f "$(tprefix S)/options/.steamlaunch-292030" && "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "$GLES" ]] || fail "sidecar missing or wrong"
[[ -f "$ST/userdata/111/config/localconfig.vdf.bak" ]] || fail "no .bak on first write"
fmt_ok "$ST/userdata/111/config/localconfig.vdf" >/dev/null || fail "LaunchOptions formatting wrong in 111"
fmt_ok "$ST/userdata/222/config/localconfig.vdf" >/dev/null || fail "LaunchOptions formatting wrong in 222"
print -r -- "ok: both accounts got LaunchOptions '$GLES'; sidecar remembered; formatting clean"

# 2. User's own LaunchOptions stay untouched; Cosmopolitan logs once.
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"-skipintro"\n'
out=$(ct --tunesteam S 2>&1)
o1=$(opts "$ST/userdata/111/config/localconfig.vdf")
[[ "$o1" == "-skipintro" ]] || fail "user LaunchOptions were overwritten: '$o1'"
print -r -- "$out" | grep -q "Steam has your own launch options for The Witcher 3; Cosmopolitan's ($GLES) not applied" \
  || fail "expected one-shot log about user's own options: $out"
print -r -- "ok: user's '-skipintro' left alone; logged once"

# 3. Stale Cosmopolitan GLES value (matches sidecar) is replaced when ARGS change.
print -r -- 'ARGS=-windowed' > "$(tprefix S)/options/REDprelauncher.exe.env"
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"'"$GLES"$'"\n'
print -r -- "$GLES" > "$(tprefix S)/options/.steamlaunch-292030"
out=$(ct --tunesteam S 2>&1)
want="$GLES -windowed"
o1=$(opts "$ST/userdata/111/config/localconfig.vdf"); o2=$(opts "$ST/userdata/222/config/localconfig.vdf")
[[ "$o1" == "$want" && "$o2" == "$want" ]] || fail "stale Cosmo value not replaced: 111='$o1' 222='$o2'"
[[ "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "$want" ]] || fail "sidecar not updated"
print -r -- "ok: stale Cosmopolitan LaunchOptions replaced with '$want'"

# 4. Steam "running" (test hook) → no write.
before=$(shasum -a 256 "$ST/userdata/111/config/localconfig.vdf" | cut -c1-16)
print -r -- 'ARGS=-nosound' > "$(tprefix S)/options/REDprelauncher.exe.env"
out=$(COSMO_TEST_STEAM_RUNNING=1 ct --tunesteam S 2>&1)
after=$(shasum -a 256 "$ST/userdata/111/config/localconfig.vdf" | cut -c1-16)
[[ "$before" == "$after" ]] || fail "wrote localconfig while Steam was 'running'"
[[ "$(opts "$ST/userdata/111/config/localconfig.vdf")" == "$want" ]] || fail "LaunchOptions changed under steam-running hook"
print -r -- "ok: COSMO_TEST_STEAM_RUNNING=1 → localconfig untouched"

# 5. LaunchOptions already equals desired (user typed GLES): adopt sidecar, no "not applied" log.
rm -f "$(tprefix S)/options/REDprelauncher.exe.env" "$(tprefix S)/options/.steamlaunch-292030"
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"'"$GLES"$'"\n'
mkcfg "$ST/userdata/222/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"'"$GLES"$'"\n'
before=$(shasum -a 256 "$ST/userdata/111/config/localconfig.vdf" | cut -c1-16)
out=$(ct --tunesteam S 2>&1)
after=$(shasum -a 256 "$ST/userdata/111/config/localconfig.vdf" | cut -c1-16)
[[ "$before" == "$after" ]] || fail "rewrote VDF when LaunchOptions already matched desired"
[[ "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "$GLES" ]] || fail "sidecar not adopted for already-equal LaunchOptions"
print -r -- "$out" | grep -q "Steam has your own launch options" && fail "logged 'not applied' for already-equal value: $out"
print -r -- "ok: already-equal LaunchOptions adopted into sidecar; no 'not applied' log; VDF untouched"

# 6. 1.3.9 legacy "--launcher-skip -dx12" (sidecar and/or bare) must be replaced with GLES; user text still untouched.
rm -f "$(tprefix S)/options/.steamlaunch-292030"
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"'"$LEGACY"$'"\n'
print -r -- "$LEGACY" > "$(tprefix S)/options/.steamlaunch-292030"
mkcfg "$ST/userdata/222/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"'"$LEGACY"$'"\n'
# 222: legacy value, no sidecar claim on that write path — still prior Cosmo string → replace
out=$(ct --tunesteam S 2>&1)
o1=$(opts "$ST/userdata/111/config/localconfig.vdf"); o2=$(opts "$ST/userdata/222/config/localconfig.vdf")
[[ "$o1" == "$GLES" && "$o2" == "$GLES" ]] || fail "1.3.9 legacy not replaced: 111='$o1' 222='$o2'"
[[ "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "$GLES" ]] || fail "sidecar not updated after legacy replace"
# Bare legacy without sidecar
rm -f "$(tprefix S)/options/.steamlaunch-292030"
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"'"$LEGACY"$'"\n'
out=$(ct --tunesteam S 2>&1)
[[ "$(opts "$ST/userdata/111/config/localconfig.vdf")" == "$GLES" ]] || fail "bare 1.3.9 legacy without sidecar not replaced"
# User text still safe
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"-skipintro"\n'
print -r -- "$GLES" > "$(tprefix S)/options/.steamlaunch-292030"
out=$(ct --tunesteam S 2>&1)
[[ "$(opts "$ST/userdata/111/config/localconfig.vdf")" == "-skipintro" ]] || fail "user options clobbered after legacy tests"
print -r -- "ok: 1.3.9 '--launcher-skip -dx12' replaced with GLES (sidecar and bare); user text untouched"

# 7. Steam was running, then exits while Cosmopolitan is inactive → GLES LaunchOptions applied.
rm -f "$(tprefix S)/options/.steamlaunch-292030"
mkcfg "$ST/userdata/111/config/localconfig.vdf"
mkcfg "$ST/userdata/222/config/localconfig.vdf"
out=$(COSMO_TEST_STEAM_RUNNING=1 ct --tunesteam S 2>&1)
[[ -z "$(opts "$ST/userdata/111/config/localconfig.vdf")" ]] || fail "wrote LaunchOptions while Steam was running (setup for exit case)"
out=$(COSMO_TEST_APP_INACTIVE=1 COSMO_TEST_STEAM_EXIT_DELAY=0 ct --steam-exit-sync S 2>&1)
print -r -- "$out" | grep -q 'status polling active: false' || fail "expected inactive status polling for exit sync: $out"
o1=$(opts "$ST/userdata/111/config/localconfig.vdf"); o2=$(opts "$ST/userdata/222/config/localconfig.vdf")
[[ "$o1" == "$GLES" && "$o2" == "$GLES" ]] || fail "after Steam exit sync (inactive): 111='$o1' 222='$o2'"
[[ "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "$GLES" ]] || fail "sidecar missing after Steam exit sync (inactive)"
fmt_ok "$ST/userdata/111/config/localconfig.vdf" >/dev/null || fail "formatting wrong after Steam exit sync"
print -r -- "ok: Steam exited while Cosmopolitan inactive → GLES LaunchOptions written (background watch)"

# 8. Steam already down: startup-style sync writes GLES LaunchOptions.
rm -f "$(tprefix S)/options/.steamlaunch-292030"
mkcfg "$ST/userdata/111/config/localconfig.vdf"
mkcfg "$ST/userdata/222/config/localconfig.vdf"
out=$(ct --steam-launch-sync S 2>&1)
o1=$(opts "$ST/userdata/111/config/localconfig.vdf"); o2=$(opts "$ST/userdata/222/config/localconfig.vdf")
[[ "$o1" == "$GLES" && "$o2" == "$GLES" ]] || fail "steam-launch-sync (already down): 111='$o1' 222='$o2'"
[[ "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "$GLES" ]] || fail "sidecar missing after steam-launch-sync"
print -r -- "ok: Steam already down → startup sync wrote GLES LaunchOptions"

tw_check || fail "your real data changed"
print "PASS steam_launch_options"
