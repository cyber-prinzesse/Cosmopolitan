#!/bin/zsh
# Steam's Play button uses LaunchOptions in userdata/*/config/localconfig.vdf. Cosmopolitan's Play already passes
# --launcher-skip -dx12 (etc.) via steam.exe -applaunch; this syncs those args into LaunchOptions while Steam is down,
# without clobbering the user's own text. Stand-in: REDprelauncher + launcher-configuration.json + bin/x64_dx12/witcher3.exe.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot

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
	}
}
VDF
}
mkcfg "$ST/userdata/111/config/localconfig.vdf"
mkcfg "$ST/userdata/222/config/localconfig.vdf"

opts() { python3 -I -c 'import re,sys; t=open(sys.argv[1],encoding="utf-8").read(); m=re.search(r"\"LaunchOptions\"\s*\"([^\"]*)\"", t); print(m.group(1) if m else "")' "$1"; }

# 1. Sync while Steam is down → both accounts get Cosmopolitan's CDPR args.
out=$(ct --tunesteam S 2>&1)
o1=$(opts "$ST/userdata/111/config/localconfig.vdf"); o2=$(opts "$ST/userdata/222/config/localconfig.vdf")
[[ "$o1" == "--launcher-skip -dx12" && "$o2" == "--launcher-skip -dx12" ]] || fail "after tunesteam: 111='$o1' 222='$o2'"
[[ -f "$(tprefix S)/options/.steamlaunch-292030" && "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "--launcher-skip -dx12" ]] || fail "sidecar missing or wrong"
[[ -f "$ST/userdata/111/config/localconfig.vdf.bak" ]] || fail "no .bak on first write"
print -r -- "ok: both userdata accounts got LaunchOptions '--launcher-skip -dx12'; sidecar remembered"

# 2. User's own LaunchOptions stay untouched; Cosmopolitan logs once.
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"-skipintro"\n'
# Sidecar still says we wrote --launcher-skip -dx12; current is the user's -skipintro.
out=$(ct --tunesteam S 2>&1)
o1=$(opts "$ST/userdata/111/config/localconfig.vdf")
[[ "$o1" == "-skipintro" ]] || fail "user LaunchOptions were overwritten: '$o1'"
print -r -- "$out" | grep -q "Steam has your own launch options for The Witcher 3; Cosmopolitan's (--launcher-skip -dx12) not applied" \
  || fail "expected one-shot log about user's own options: $out"
print -r -- "ok: user's '-skipintro' left alone; logged once"

# 3. Stale Cosmopolitan value (matches sidecar) is replaced when desired args change.
print -r -- 'ARGS=-windowed' > "$(tprefix S)/options/REDprelauncher.exe.env"
# Put Cosmo's previous value back as LaunchOptions + sidecar; account 222 still has the old synced value from step 1.
mkcfg "$ST/userdata/111/config/localconfig.vdf" $'\t\t\t\t\t\t"LaunchOptions"\t\t"--launcher-skip -dx12"\n'
print -r -- '--launcher-skip -dx12' > "$(tprefix S)/options/.steamlaunch-292030"
out=$(ct --tunesteam S 2>&1)
o1=$(opts "$ST/userdata/111/config/localconfig.vdf"); o2=$(opts "$ST/userdata/222/config/localconfig.vdf")
[[ "$o1" == "--launcher-skip -dx12 -windowed" && "$o2" == "--launcher-skip -dx12 -windowed" ]] \
  || fail "stale Cosmo value not replaced: 111='$o1' 222='$o2'"
[[ "$(cat "$(tprefix S)/options/.steamlaunch-292030")" == "--launcher-skip -dx12 -windowed" ]] || fail "sidecar not updated"
print -r -- "ok: stale Cosmopolitan LaunchOptions replaced with '--launcher-skip -dx12 -windowed'"

# 4. Steam "running" (test hook) → no write.
before=$(shasum -a 256 "$ST/userdata/111/config/localconfig.vdf" | cut -c1-16)
print -r -- 'ARGS=-nosound' > "$(tprefix S)/options/REDprelauncher.exe.env"
out=$(COSMO_TEST_STEAM_RUNNING=1 ct --tunesteam S 2>&1)
after=$(shasum -a 256 "$ST/userdata/111/config/localconfig.vdf" | cut -c1-16)
[[ "$before" == "$after" ]] || fail "wrote localconfig while Steam was 'running'"
[[ "$(opts "$ST/userdata/111/config/localconfig.vdf")" == "--launcher-skip -dx12 -windowed" ]] || fail "LaunchOptions changed under steam-running hook"
print -r -- "ok: COSMO_TEST_STEAM_RUNNING=1 → localconfig untouched"

tw_check || fail "your real data changed"
print "PASS steam_launch_options"
