#!/bin/sh
# Packs Cosmopolitan for another Mac: the app + engine + drivers + codecs (no bottles). Output: dist/Cosmopolitan-<date>.tgz
# On the other Mac: untar and run ./install.sh. It clears the download quarantine, so the app (ad-hoc signed, not notarized) opens
# without the Gatekeeper prompt; right-click › Open no longer bypasses that prompt on macOS 15 and later.
set -e; cd "$(dirname "$0")/.."; scripts/build.sh
S="$HOME/Library/Application Support/Cosmopolitan"; D="dist/stage"; rm -rf dist; mkdir -p "$D/support/engines"
cp -cR build.noindex/Cosmopolitan.app "$D/"
cp -cR "$S/engines/WS12WineSikarugir10.0_8" "$S/engines/renderer" "$S/engines/gstreamer" "$D/support/engines/"
# D3DMetal is Apple's proprietary software and must never be in a release artifact (see THIRD_PARTY_NOTICES.md).
rm -rf "$D/support/engines/renderer/d3dmetal" "$D/support/engines/renderer/d3dmetal.old" "$D/support/engines/renderer/d3dmetal.bad"
if find "$D" \( -name 'D3DMetal.framework' -o -name 'libd3dshared.dylib' \) | grep -q .; then echo "ABORT: D3DMetal files in release artifact"; exit 1; fi
cp THIRD_PARTY_NOTICES.md README.md "$D/"
cat > "$D/install.sh" <<'I'
#!/bin/sh
# Installs Cosmopolitan into /Applications and its engine/drivers into ~/Library/Application Support/Cosmopolitan.
set -e; cd "$(dirname "$0")"; S="$HOME/Library/Application Support/Cosmopolitan"
mkdir -p "$S/engines" "$S/bottles"; cp -R support/engines/. "$S/engines/"
# Absolute paths inside the package point at the builder's home; rewrite them for this user.
grep -rl "/Users/[^/]*/Library/Application Support/Cosmopolitan" "$S/engines" 2>/dev/null | grep -v '\.dylib$\|\.so$\|/bin/' | while read f; do
  sed -i '' "s|/Users/[^/]*/Library/Application Support/Cosmopolitan|$S|g" "$f"; done
find "$S/engines" -type l | while read l; do t=$(readlink "$l"); case "$t" in /Users/*) ln -sfn "$(echo "$t" | sed "s|/Users/[^/]*/Library/Application Support/Cosmopolitan|$S|")" "$l";; esac; done
rm -rf /Applications/Cosmopolitan.app; cp -R Cosmopolitan.app /Applications/
xattr -dr com.apple.quarantine /Applications/Cosmopolitan.app "$S/engines" 2>/dev/null || true
echo "Installed. Open /Applications/Cosmopolitan.app."
I
chmod +x "$D/install.sh"
OUT="dist/Cosmopolitan-$(date +%Y%m%d).tgz"; tar -czf "$OUT" -C "$D" .; rm -rf "$D"
du -sh "$OUT"
