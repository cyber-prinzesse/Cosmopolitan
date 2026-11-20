#!/bin/zsh
# P2 (supply-chain): every pinned download in Components.swift has a 64-char lowercase-hex sha256 and an https:// url.
cd "${0:A:h}/../.."
# Collect all sha256 values between the quotes
sha_vals=(${(f)"$(grep 'sha256: "' Sources/Core/Components.swift | sed 's/.*sha256: "//;s/".*//')"})
[[ ${#sha_vals[@]} -eq 0 ]] && { print "FAIL: no pins found in Components.swift"; exit 1; }
bad=0
for v in $sha_vals; do
  if [[ ! "$v" =~ ^[0-9a-f]{64}$ ]]; then
    print -r -- "FAIL: sha256 not 64 lowercase hex: $v"
    (( bad++ ))
  fi
done
[[ $bad -gt 0 ]] && exit 1
# Collect all url values between the quotes
url_vals=(${(f)"$(grep 'url: "' Sources/Core/Components.swift | sed 's/.*url: "//;s/".*//')"})
for v in $url_vals; do
  if [[ ! "$v" =~ ^https:// ]]; then
    print -r -- "FAIL: url does not start with https://: $v"
    (( bad++ ))
  fi
done
[[ $bad -gt 0 ]] && exit 1
print "ok: ${#sha_vals[@]} pins: sha256 64-hex, https urls"
print "PASS pin_format"
