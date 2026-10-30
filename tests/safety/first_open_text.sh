#!/bin/zsh
# P1 (oracle findings): no first-open advice that stopped working. On macOS 15 and later right-click › Open
# no longer gets an app that isn't notarized past Gatekeeper; README has the steps that work (Privacy & Security › Open Anyway).
# Every user-facing text in the repo: a line telling you to right-click and Open, unless it says that no longer works.
cd "${0:A:h}/../.."
bad=$(grep -rn -i -E "right[- ]click" README.md scripts Sources docs TERMS.txt THIRD_PARTY_NOTICES.md 2>/dev/null | grep -i "open" | grep -v -i "no longer")
[[ -z "$bad" ]] || { print -r -- "FAIL: right-click › Open advice for the first launch:"; print -r -- "$bad"; exit 1; }
print "ok: no right-click › Open advice (checked README, scripts, Sources, docs)"
print "PASS first_open_text"
