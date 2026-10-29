#!/bin/zsh
# Steam's own window draws on the engine under test (Wine 11 engines: black or missing unless the launch code puts Steam's web views on
# the GPU and lets DXMT draw across processes; measured 24 Oct with tests/oracle/launcher.sh, CrossOver 26.3 as the reference).
# A throwaway bottle, Valve's SteamSetup.exe installed silently, Steam started through Cosmopolitan (its flags, environment and the
# GPUAccelWebViewsV3 value on Wine 11), then screenshots of Steam's largest window while it runs: PASS when it isn't uniformly dark.
# Not logged in, no account; your Steam is never touched. Usage: COSMO_ENGINE=… COSMO_ENGINE_DIR=… tests/ui/steam_window.sh [seconds]
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; trap testenv_cleanup EXIT
fail() { print -r -- "FAIL: $*"; exit 1; }
tw_snapshot
swiftc -O "$TESTENV_REPO/tests/lib/winshot.swift" -o "$T/winshot" 2>/dev/null || fail "could not build winshot"
ct --newbottle S >/dev/null 2>&1; [[ -d "$(tprefix S)/drive_c" ]] || fail "throwaway bottle not created"
curl -fsSL --retry 3 -o "$T/SteamSetup.exe" "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe" || fail "no Steam installer"
print "steam installer: $(shasum -a 256 "$T/SteamSetup.exe" | cut -c1-16)…, $(stat -f %z "$T/SteamSetup.exe") bytes"
cp "$T/SteamSetup.exe" "$(tprefix S)/drive_c/SteamSetup.exe"; twine S 'C:\SteamSetup.exe' /S >/dev/null 2>&1   # bottles are C:-only (no Z:)
ST="$(tprefix S)/drive_c/Program Files (x86)/Steam/steam.exe"; [[ -f "$ST" ]] || fail "Steam was not installed"
for kv in ${=STEAM_EXTRA_ENV:-}; do print -r -- "$kv" >> "$(tprefix S)/cosmopolitan.env"; done   # e.g. STEAM_EXTRA_ENV="DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1"
secs=${1:-300}; ct --launch S "$ST" $secs > "$T/launch.out" 2>&1 &
lum() {   # mean brightness 0–255 of a PNG and the share of pixels brighter than 24, via an uncompressed BMP
  sips -s format bmp "$1" --out "$1.bmp" >/dev/null 2>&1 && python3 -I -c '
import struct, sys
d = open(sys.argv[1], "rb").read(); off, w, h, bpp = struct.unpack_from("<I", d, 10)[0], *struct.unpack_from("<iiHH", d, 18)[0:2], struct.unpack_from("<H", d, 28)[0]
n = bpp // 8; row = (w * n + 3) & ~3; tot = lit = cnt = 0
for y in range(0, abs(h), 4):
    for x in range(0, w, 4):
        b, g, r = d[off + y * row + x * n: off + y * row + x * n + 3]; v = (r + g + b) // 3; tot += v; cnt += 1; lit += v > 24
print(f"{tot // max(cnt, 1)} {100 * lit // max(cnt, 1)}")' "$1.bmp"; }
best=0; t0=$EPOCHREALTIME; shot=""
while (( EPOCHREALTIME - t0 < secs - 10 )); do
  sleep 15; pids=($(pgrep -if 'steam' | while read p; do [[ "$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "${$(tprefix S):A}"/* ]] && print $p; done))
  (( ${#pids} )) || continue; pid=${pids[1]}
  rm -f "$T"/w-*.png(N); for p in $pids; do "$T/winshot" $p "$T/w-$p" >/dev/null 2>&1; done   # Steam's window may belong to steamwebhelper, not steam.exe
  big=$(for f in "$T"/w-*.png(N); do print "$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/{print $2}') $f"; done | sort -rn | head -1)
  [[ -n "$big" ]] || { print -r -- "  $(printf '%3.0f' $(( EPOCHREALTIME - t0 ))) s: ${#pids} Steam processes, no window on screen yet"; continue; }
  w=${big%% *}; cp "${big#* }" "$T/steam-1.png"
  (( w >= 1000 )) || { print -r -- "  (a ${w}px Steam window; waiting for the main one)"; continue; }
  read m l <<< "$(lum "$T/steam-1.png")"; print -r -- "  $(printf '%3.0f' $(( EPOCHREALTIME - t0 ))) s: Steam window $(sips -g pixelWidth -g pixelHeight "$T/steam-1.png" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')px, mean brightness $m, lit $l%"
  (( l > best )) && { best=$l; cp "$T/steam-1.png" "$T/best.png"; }
  (( best > 20 )) && break
done
reg=$(twine S reg query 'HKCU\Software\Valve\Steam' /v GPUAccelWebViewsV3 2>/dev/null | tr -d '\r' | grep -o '0x[0-9a-f]*')
args=$(ps -o command= -p ${pid:-0} 2>/dev/null | grep -o -- '-cef-[a-z0-9-]*' | tr '\n' ' ')
print -r -- "  GPUAccelWebViewsV3: ${reg:-not set}; Steam's -cef flags: ${args:-none}"
[[ -n "${SHOTS:-}" && -f "$T/best.png" ]] && cp "$T/best.png" "$SHOTS/steam-window-$ENGINE.png"
print -r -- "  webhelper GPU: $(grep -m3 -iE "swiftshader|gpu.*(active|enabled|disabled)|angle" "$(tprefix S)/drive_c/Program Files (x86)/Steam/logs/webhelper_gpu.txt" 2>/dev/null | tr -s " " | tr "\n" "|" | cut -c1-220)"
[[ -n "${SHOTS:-}" ]] && cp -R "$(tprefix S)/drive_c/Program Files (x86)/Steam/logs" "$SHOTS/steam-logs-$ENGINE" 2>/dev/null   # for a look afterwards
pkill -f "$T/CosmopolitanTest.app" 2>/dev/null; wait 2>/dev/null
tw_check || fail "your real data changed"
(( best > 20 )) && print "PASS steam_window ($ENGINE: $best% of the window lit)" || fail "Steam's window stayed dark on $ENGINE (best $best% lit)"
