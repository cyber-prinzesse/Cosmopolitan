#!/bin/zsh
# SEC-003: graphics drivers install only verified files.
# - Weekly/automatic path (--update --install): only the pinned release; wrong bytes at the pinned URL install nothing.
# - Drivers › Update… path (--update --install --newest): the newest upstream release, only if its file matches the SHA-256 digest
#   GitHub publishes for that asset; a missing or wrong digest installs nothing; a matching one installs and keeps <name>.old.
# Upstream is a local stand-in (file:// release JSON + tarball), so nothing is downloaded from the network.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
R="$TS/engines/renderer"; [[ -d "$R/dxmt" ]] || fail "no dxmt in the test drivers: $(ls "$R")"
mkdir -p "$T/pkg/dxmt-v9.9/wine/x86_64-windows"; print fake > "$T/pkg/dxmt-v9.9/wine/x86_64-windows/d3d11.dll"
tar czf "$T/dxmt-v9.9-builtin.tar.gz" -C "$T/pkg" dxmt-v9.9 || fail "stand-in tarball"
good=$(shasum -a 256 "$T/dxmt-v9.9-builtin.tar.gz" | cut -d' ' -f1)
rel() { print -r -- "{\"tag_name\":\"v9.9\",\"assets\":[{\"name\":\"dxmt-v9.9-builtin.tar.gz\",\"browser_download_url\":\"file://$T/dxmt-v9.9-builtin.tar.gz\"$1}]}" > "$T/rel.json"; }
export COSMO_TEST_DRIVER_API_dxmt="file://$T/rel.json" COSMO_TEST_DRIVER_API_dxvk="file://$T/none.json" COSMO_TEST_DRIVER_API_dxvk3="file://$T/none.json"
before=$(cat "$R/dxmt/version")

rel ""; out=$(ct --update --install --newest 2>&1)
[[ "$(cat "$R/dxmt/version")" == "$before" && "$out" == *"no checksum"* ]] || fail "no digest: installed anyway or no refusal: $(print -r -- "$out" | grep dxmt)"
print "ok: upstream release without a GitHub digest is refused"
rel ",\"digest\":\"sha256:$(print -n x | shasum -a 256 | cut -d' ' -f1)\""; out=$(ct --update --install --newest 2>&1)
[[ "$(cat "$R/dxmt/version")" == "$before" && "$out" == *"checksum mismatch"* ]] || fail "wrong digest: $(print -r -- "$out" | grep dxmt)"
print "ok: upstream file that doesn't match GitHub's digest is refused, drivers unchanged"
rel ",\"digest\":\"sha256:$good\""; out=$(ct --update 2>&1)
[[ "$(cat "$R/dxmt/version")" == "$before" && "$out" == *"upstream v9.9 is available"* ]] || fail "--update alone must only report: $(print -r -- "$out" | grep dxmt)"
out=$(ct --update --install 2>&1)
[[ "$(cat "$R/dxmt/version")" == "$before" ]] || fail "the automatic path installed an unpinned upstream release: $(print -r -- "$out" | grep dxmt)"
print "ok: the automatic path (--update --install) leaves a newer upstream release alone"
out=$(ct --update --install --newest 2>&1)
[[ "$(cat "$R/dxmt/version")" == v9.9 && -f "$R/dxmt/wine/x86_64-windows/d3d11.dll" && -d "$R/dxmt.old" ]] || fail "matching digest did not install: $(print -r -- "$out" | grep dxmt)"
print "ok: matching digest installs v9.9 from Drivers › Update…, previous kept as dxmt.old"
out=$(ct --update --install 2>&1)
[[ "$(cat "$R/dxmt/version")" == v9.9 ]] || fail "the weekly path downgraded a verified newer driver: $(print -r -- "$out" | grep dxmt)"
print "ok: the weekly path keeps the newer verified v9.9 (no downgrade to the pin)"

# Pinned path: drivers older than the pin fetch the pinned file; wrong bytes at its URL install nothing.
rm -rf "$R/dxmt"; mv "$R/dxmt.old" "$R/dxmt"; print old > "$R/dxmt/version"
print junk > "$T/junk.tar.gz"; out=$(COSMO_TEST_URL_dxmt_v0_80_tar_gz="file://$T/junk.tar.gz" ct --update --install 2>&1)
[[ "$(cat "$R/dxmt/version")" == old && "$out" == *"checksum mismatch"* ]] || fail "pinned path accepted wrong bytes: $(print -r -- "$out" | grep -i dxmt)"
print "ok: the pinned release is refused when its bytes don't match the pinned SHA-256"
tw_check || fail "your real data changed"
print "PASS driver_pins"
