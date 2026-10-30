#!/bin/zsh
# Item 22: GOG sign-in. Only the address GOG's login lands on (https, gog.com, on_login_success, a code) is caught. The address goes to
# lgogdownloader and the result is "Signed in to GOG." or a clear reason: a bad code (lgogdownloader's own words), no answer in time,
# not installed, not a GOG address. A stand-in replaces lgogdownloader: no GOG account, no real sign-in. The sign-in data lands in the
# throwaway home; your own ~/.config/lgogdownloader is only hashed, before and after. With SHOTS=dir, the sheet itself is captured:
# GOG's real login page (loaded, nothing typed), then signed in and failed (a local page redirects to the success address, which the
# sheet catches before anything is sent).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
REAL_GOG="$REAL_HOME/.config/lgogdownloader"; gog_hash() { cat "$REAL_GOG"/*(N.) 2>/dev/null | shasum -a 256 | cut -c1-16; }; gog0=$(gog_hash)
cat > "$T/lgog" <<'S'
#!/bin/sh
# Stand-in for lgogdownloader --browser-login: reads the address; "code=good" signs in, "code=slow" never answers, anything else fails.
read -r url
case "$url" in
  *code=good*) mkdir -p "$HOME/.config/lgogdownloader" && printf '{"access_token":"stand-in","refresh_token":"stand-in","expires_in":3600}\n' > "$HOME/.config/lgogdownloader/galaxy_tokens.json" && echo "Login successful (stand-in)";;
  *code=slow*) sleep 600;;
  *) echo "Paste the address of the page you land on: https://auth.gog.com/auth?..."; echo "Error: invalid authorization code (stand-in)"; exit 1;;
esac
S
chmod +x "$T/lgog"
GOOD='https://embed.gog.com/on_login_success?origin=client&code=good'
redirect() { ct --gog-redirect "$1" 2>&1 | grep -E '^(caught|not a sign-in address)$'; }
for u in "$GOOD" 'https://login.gog.com/on_login_success?code=x1'; do [[ "$(redirect "$u")" == caught ]] || fail "not caught: $u"; done
for u in 'https://embed.gog.com/on_login_success?origin=client' 'https://embed.gog.com/on_login_success?origin=client&code=' 'https://notgog.com/on_login_success?code=x1' \
         'http://embed.gog.com/on_login_success?code=x1' 'https://auth.gog.com/auth?client_id=46899977096215655&response_type=code' 'https://evil.example/on_login_success?code=x1&gog.com'; do
  [[ "$(redirect "$u")" == "not a sign-in address" ]] || fail "wrongly caught: $u"
done
print "ok: the success address is caught; no code, another host (notgog.com), http, GOG's login page itself and look-alikes are not"
signin() { COSMO_TEST_LGOG="${LG:-$T/lgog}" ct --gog-signin "$1" 2>&1 | grep -E '^(Signed in|Sign-in failed)'; }
out=$(signin "$GOOD"); [[ "$out" == "Signed in to GOG." && -s "$TH/.config/lgogdownloader/galaxy_tokens.json" ]] || fail "good code: '$out'"
print "ok: good code → '$out' (sign-in data in the throwaway home's .config/lgogdownloader)"
rm -f "$TH/.config/lgogdownloader/galaxy_tokens.json"
out=$(signin "${GOOD/good/bad}"); [[ "$out" == "Sign-in failed: Error: invalid authorization code (stand-in)" ]] || fail "bad code: '$out'"
print "ok: bad code → '$out'"
t0=$EPOCHREALTIME; out=$(COSMO_TEST_GOG_TIMEOUT=3 signin "${GOOD/good/slow}")
[[ "$out" == "Sign-in failed: GOG didn't answer within 3 seconds. Check the internet connection and try again." ]] || fail "no answer: '$out'"
print "ok: no answer → '$out' after $(printf %.1f $((EPOCHREALTIME - t0))) s"
out=$(LG=/nonexistent/lgogdownloader signin "$GOOD"); [[ "$out" == "Sign-in failed: lgogdownloader isn't installed (Stores… › Set up GOG)." ]] || fail "not installed: '$out'"
print "ok: not installed → '$out'"
out=$(signin 'https://example.com/?code=good'); [[ "$out" == "Sign-in failed: that isn't the address GOG's login ends on"* ]] || fail "wrong address: '$out'"
print "ok: a pasted address that isn't GOG's → '$out'"

if [[ -n "${SHOTS:-}" ]]; then   # the sheet in the GUI test build
  mkdir -p "$SHOTS"; swiftc -O "$TESTENV_REPO/tests/lib/winshot.swift" -o "$T/winshot" || fail "could not build winshot"
  gui() {   # gui NAME LOGIN-URL WAIT-FOR-LOG-LINE: opens the sheet, waits for the line (or 20 s for a page load), captures, quits
    rm -f "$TH/.config/lgogdownloader/galaxy_tokens.json"; local L="$TH/Library/Logs/Cosmopolitan.log"
    sandbox-exec -p "$(tw_sandbox_profile)" env CFFIXED_USER_HOME="$TH" HOME="$TH" COSMO_TEST_HOME="$TH" COSMO_TEST_SHEET=gog-login COSMO_TEST_LGOG="$T/lgog" \
      ${2:+COSMO_TEST_GOG_LOGIN_URL="$2"} "$T/CosmopolitanTest.app/Contents/MacOS/Cosmopolitan" >/dev/null 2>&1 & local app=$!
    seen() { grep -q "$1" "$L" 2>/dev/null; }; win() { "$T/winshot" $app "$T/probe" >/dev/null 2>&1; }
    poll 30 win || { kill $app; fail "$1: no window"; }
    if [[ -n "$3" ]]; then poll 30 seen "$3" || { kill $app; fail "$1: '$3' never appeared"; }; sleep 1; else sleep 20; fi   # 1 s: let the sheet redraw
    "$T/winshot" $app "$SHOTS/gog-$1" | sed 's/^/  shot: /'; kill $app; wait $app 2>/dev/null
  }
  page() { python3 -I -c 'import sys, urllib.parse; print("data:text/html," + urllib.parse.quote("<body style=\"font:16px -apple-system\">Stand-in login page (test)<script>setTimeout(function(){location.href=\"" + sys.argv[1] + "\"},1500)</script>"))' "$1"; }
  gui login-page "" ""
  gui signed-in "$(page "$GOOD")" "Signed in to GOG."
  gui failed "$(page "${GOOD/good/bad}")" "Sign-in failed"
fi
[[ "$(gog_hash)" == "$gog0" ]] || fail "your own ~/.config/lgogdownloader changed"
print "ok: your own ~/.config/lgogdownloader is unchanged"
tw_check || fail "your real data changed"
print "PASS gog_signin"
