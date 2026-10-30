#!/bin/zsh
# Item 31: template bottles. The first bottle made with this engine becomes a clean template once it is complete (Wine Mono in); the next
# bottle is one clonefile of it (APFS private size 0: every block shared), ready in seconds; a new engine version gets a fresh template and
# the old one goes.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; exit 1; }
tw_snapshot
clang -O2 -x c -o "$T/privsize" - <<'C' || fail "could not build the private-size probe"
#include <sys/attr.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
int main(int c, char **v) {
    struct attrlist al = {0}; al.bitmapcount = ATTR_BIT_MAP_COUNT; al.commonattr = ATTR_CMN_RETURNED_ATTRS; al.forkattr = ATTR_CMNEXT_PRIVATESIZE;
    struct __attribute__((packed)) { uint32_t len; attribute_set_t ret; off_t priv; } b;
    if (c < 2 || getattrlist(v[1], &al, &b, sizeof b, FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW) || !(b.ret.forkattr & ATTR_CMNEXT_PRIVATESIZE)) { puts("-1"); return 1; }
    printf("%lld\n", (long long)b.priv); return 0;
}
C
took() { print -r -- "$1" | sed -n 's/^newbottle: [A-Z] ready after \([0-9.]*\) s$/\1/p'; }
out=$(ct --newbottle A 2>&1); ta=$(took "$out"); [[ -n "$ta" ]] || fail "A not ready: $(print -r -- "$out" | tail -3)"
tpl=$(ls "$TS/templates" 2>/dev/null); [[ -n "$tpl" && -d "$TS/templates/$tpl/drive_c/windows/mono" ]] || fail "no complete template after the first bottle: '$tpl'"
print "ok: bottle A built the normal way in $ta s and became the template '$tpl'"
out=$(ct --newbottle B 2>&1); tb=$(took "$out")
[[ "$out" == *"Bottle B: made from the clean template ($tpl)."* && -n "$tb" ]] || fail "B was not made from the template: $(print -r -- "$out" | tail -3)"
B="$(tprefix B)"; [[ -d "$B/drive_c/windows/mono" ]] && grep -q '"DisableHidraw"=dword:00000001' "$B/system.reg" || fail "B lacks Wine Mono or the controller setting"
f=$(ls -S "$B/drive_c/windows/system32/"*.dll | head -1); p=$("$T/privsize" "$f")
[[ "$p" == 0 ]] || fail "B's ${f:t} holds $p bytes of its own: not a clone"
(( ${tb%.*} < 15 )) || fail "B took $tb s"
print "ok: bottle B came from the template in $tb s (A: $ta s); Wine Mono and the controller setting are in; its biggest DLL ${f:t} shares every block (private size 0)"
out=$(COSMO_TEST_ENGINE_VERSION=wine-99.0 ct --newbottle C 2>&1)
[[ "$out" != *"made from the clean template"* ]] || fail "C used the old engine's template"
new=$(ls "$TS/templates"); [[ "$new" == *"wine-99.0"* && "$new" != *"$tpl"* ]] || fail "templates after the engine change: $new"
print "ok: with a new engine version C was built the normal way, and the template is now '$new' (the old one removed)"
tw_check || fail "your real data changed"
print "PASS templates"
