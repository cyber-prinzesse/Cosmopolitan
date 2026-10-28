#!/bin/sh
# Release: builds the app, zips it, signs it with the Sparkle EdDSA key and (re)generates dist/appcast.xml.
# Usage: COSMO_VERSION=1.1 ./release.sh      then upload dist/*.zip and dist/appcast.xml to the feed location (SUFeedURL in build.sh,
# override with COSMO_FEED_URL=https://… ). The private key lives in the login Keychain (created by Sparkle/bin/generate_keys).
set -e; cd "$(dirname "$0")/.."
export COSMO_VERSION=${COSMO_VERSION:-1.0}; export COSMO_BUILD=${COSMO_BUILD:-$(date +%Y%m%d%H%M)}
scripts/build.sh
# The binary must run on the oldest macOS the app declares (LSMinimumSystemVersion, from MIN in build.sh). 1.3.2 was built on macOS 27
# without a deployment target, came out minos 27.0 and wouldn't open on 26 (Tahoe); such a build is never released.
MINOS=$(vtool -show-build Cosmopolitan.app/Contents/MacOS/Cosmopolitan | awk '/minos/{print $2; exit}'); LSMIN=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Cosmopolitan.app/Contents/Info.plist 2>/dev/null || true)
[ -n "$MINOS" ] && [ "$MINOS" = "$LSMIN" ] || { echo "Cosmopolitan.app needs macOS ${MINOS:-?} but declares ${LSMIN:-nothing}: not releasing (see MIN in scripts/build.sh)"; exit 1; }
mkdir -p dist; rm -f "dist/Cosmopolitan-$COSMO_VERSION.zip" "dist/Cosmopolitan-$COSMO_VERSION.dSYM.zip"
ditto -c -k --sequesterRsrc --keepParent Cosmopolitan.app "dist/Cosmopolitan-$COSMO_VERSION.zip"
# Debug symbols: separate archive, same version. Symbolicate a crash report with:
#   atos -o Cosmopolitan.app.dSYM/Contents/Resources/DWARF/Cosmopolitan -arch arm64 -l <load address> <crash addresses>
mkdir -p dsyms; ditto -c -k --keepParent Cosmopolitan.app.dSYM "dist/Cosmopolitan-$COSMO_VERSION.dSYM.zip"
cp -R Cosmopolitan.app.dSYM "dsyms/Cosmopolitan-$COSMO_VERSION-$COSMO_BUILD.dSYM"   # local archive of every shipped build's symbols
# DMG for first-time downloads (Sparkle updates from the zip): the app plus an Applications shortcut, compressed.
rm -rf dist/dmgroot "dist/Cosmopolitan-$COSMO_VERSION.dmg"; mkdir -p dist/dmgroot && cp -R Cosmopolitan.app dist/dmgroot/ && ln -s /Applications dist/dmgroot/Applications
# macOS 26+: `diskutil image` (2 s); hdiutil is deprecated there and stalled for minutes on macOS 27. Older systems fall back to it.
diskutil image create from dist/dmgroot "dist/Cosmopolitan-$COSMO_VERSION.dmg" --format UDZO --volumeName "Cosmopolitan $COSMO_VERSION" >/dev/null 2>&1 \
  || hdiutil create -quiet -volname "Cosmopolitan $COSMO_VERSION" -srcfolder dist/dmgroot -ov -format UDZO "dist/Cosmopolitan-$COSMO_VERSION.dmg"
rm -rf dist/dmgroot
# Appcast: generate_appcast signs the app zip with the EdDSA key and writes the feed; the enclosure URL points at this version's GitHub release,
# and the feed itself is served from the *latest* release (SUFeedURL in build.sh), so publishing a release is publishing the update.
REPO=${COSMO_REPO:-cyber-prinzesse/Cosmopolitan}
# The Keychain lets generate_keys (which created the key) read it but prompts for generate_appcast, which fails when no one can click;
# so the key is exported to a private temp file for the few seconds of signing and shredded again.
KEYDIR=$(mktemp -d) && KEYFILE="$KEYDIR/sparkle.key" && ./Sparkle/bin/generate_keys -x "$KEYFILE" >/dev/null   # refuses an existing file
rm -rf dist/appcast; mkdir -p dist/appcast && cp "dist/Cosmopolitan-$COSMO_VERSION.zip" dist/appcast/ && ./Sparkle/bin/generate_appcast --ed-key-file "$KEYFILE" --download-url-prefix "https://github.com/$REPO/releases/download/v$COSMO_VERSION/" dist/appcast/ && mv dist/appcast/appcast.xml dist/appcast.xml && rm -rf dist/appcast
rm -P -f "$KEYFILE"; rmdir "$KEYDIR"
grep -q "sparkle:edSignature" dist/appcast.xml || { echo "appcast is not signed, aborting"; exit 1; }
echo "Release $COSMO_VERSION ($COSMO_BUILD):"
echo "  dist/Cosmopolitan-$COSMO_VERSION.zip        the app (Sparkle update item)"
echo "  dist/Cosmopolitan-$COSMO_VERSION.dSYM.zip   debug symbols (attach to the GitHub release; never inside the app)"
echo "  dist/appcast.xml                          signed feed; host it at the SUFeedURL in build.sh"
# Upload when a GitHub remote exists: the appcast can be served straight from the release assets
#   (SUFeedURL = https://github.com/<user>/<repo>/releases/latest/download/appcast.xml).
if command -v gh >/dev/null && git remote get-url origin >/dev/null 2>&1; then
  PREV=$(git describe --tags --abbrev=0 2>/dev/null || true); NOTES="Build $COSMO_BUILD. Download the .dmg to install; running copies update themselves from this release.

Changes:
$(git log --format='- %s' ${PREV:+$PREV..}HEAD | head -40)"
  gh release create "v$COSMO_VERSION" "dist/Cosmopolitan-$COSMO_VERSION.dmg" "dist/Cosmopolitan-$COSMO_VERSION.zip" "dist/Cosmopolitan-$COSMO_VERSION.dSYM.zip" dist/appcast.xml --title "Cosmopolitan $COSMO_VERSION" --notes "$NOTES" || echo "gh release failed (already exists?)"
  # gh creates the release as a draft and publishes after the uploads; if that last step fails the release stays a draft and the
  # feed keeps serving the previous version, so publish explicitly (idempotent).
  gh release edit "v$COSMO_VERSION" --draft=false --latest >/dev/null 2>&1 || true
  gh release view "v$COSMO_VERSION" --json isDraft,assets --jq '"published: draft=\(.isDraft), \(.assets | length) assets"'
else echo "No GitHub remote yet: add one (git remote add origin …) and rerun to upload with gh."; fi
echo "Note: the app zip contains no D3DMetal; engines/drivers are fetched by the app itself (see dist.sh for the full offline bundle)."
