#!/bin/zsh
# Mod manager safety (1.3.35). A zip with an entry that climbs out of its folder ("../") or is absolute is refused before extraction
# (zip-slip). Disabling a mod deletes its .backup only when every original came back: a restore that fails (here: the game file is
# locked with uchg, like a full disk would) keeps the backup and the "enabled" mark, and a retry restores the original. An original that
# cannot be backed up is never overwritten and never deleted later. Re-adding an enabled mod and a second enable are refused.
# A mod name that is a dot-name is refused (it would point rm -rf at the mods folder itself).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { chflags -R nouchg "$T" 2>/dev/null; print "FAIL: $*"; exit 1; }
unlock() { chflags -R nouchg "$T" 2>/dev/null; }   # a locked file must never outlive the test (rm -rf "$T" cannot delete it)
trap 'unlock; testenv_cleanup' EXIT; trap 'unlock; testenv_cleanup; exit 130' INT; trap 'unlock; testenv_cleanup; exit 143' TERM
tw_snapshot
ct --newbottle Q >/dev/null 2>&1; [[ -d "$(tprefix Q)/drive_c" ]] || fail "throwaway bottle not created"
G="$(tprefix Q)/drive_c/Program Files (x86)/Steam/steamapps/common/ModGame"; mkdir -p "$G/data"
EXE="$G/ModGame.exe"; print exe > "$EXE"; print original > "$G/data/a.txt"
MD="$(tprefix Q)/mods/$(basename "$EXE" .exe)"

# 1. zip-slip: entries "../evil.txt" and "/tmp/abs.txt" must never be written
python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("ok.txt","x"); z.writestr("../evil.txt","evil"); z.close()' "$T/slip.zip"
out=$(ct --addmod Q "$EXE" "$T/slip.zip" 2>&1)
[[ "$out" == *"Mod add refused"*"outside its folder"* ]] || fail "zip with ../ entry not refused: $(print -r -- "$out" | grep -i mod)"
[[ ! -e "$MD/evil.txt" && ! -e "$(dirname "$MD")/evil.txt" && ! -d "$MD/slip" ]] || fail "zip-slip entry was extracted"
print "ok: a zip with a ../ entry is refused and nothing is extracted"
python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("/tmp/abs-79fd.txt","x"); z.close()' "$T/abs.zip"
out=$(ct --addmod Q "$EXE" "$T/abs.zip" 2>&1); [[ "$out" == *"Mod add refused"* && ! -e /tmp/abs-79fd.txt ]] || fail "zip with an absolute entry not refused"
print "ok: a zip with an absolute entry is refused"
mkdir -p "$T/.." 2>/dev/null; print x > "$T/..zip"
out=$(ct --addmod Q "$EXE" "$T/..zip" 2>&1); [[ "$out" == *"Mod add refused"* ]] || fail "dot-name mod not refused: $(print -r -- "$out" | grep -i mod)"
print "ok: a mod whose name is a dot-name is refused"

# 2. a normal mod replaces data/a.txt and backs the original up
mkdir -p "$T/Better/data"; print modded > "$T/Better/data/a.txt"
ct --addmod Q "$EXE" "$T/Better" >/dev/null 2>&1; ct --mod Q "$EXE" Better on >/dev/null 2>&1
[[ "$(cat "$G/data/a.txt")" == modded && "$(cat "$MD/Better/.backup/data/a.txt")" == original ]] || fail "enable: game file or backup wrong"
print "ok: enabling installs the mod file and backs the original up"

# 3. the restore fails (locked file): the backup and the enabled mark stay; remove refuses; a retry restores
chflags uchg "$G/data/a.txt"
out=$(ct --mod Q "$EXE" Better off 2>&1)
[[ "$out" == *"Mod disable incomplete"* && -f "$MD/Better/.backup/data/a.txt" && -f "$MD/Better/.enabled" ]] || fail "failed restore deleted the backup or claimed success: $(print -r -- "$out" | grep -i mod)"
print "ok: a failed restore keeps .backup and the enabled mark, and says so"
chflags nouchg "$G/data/a.txt"
out=$(ct --mod Q "$EXE" Better off 2>&1)
[[ "$(cat "$G/data/a.txt")" == original && ! -e "$MD/Better/.backup" && ! -e "$MD/Better/.enabled" && "$out" == *"originals restored"* ]] || fail "retry did not restore: $(print -r -- "$out" | grep -i mod)"
print "ok: the retry restores the original and only then drops the backup"

# 4. re-adding an enabled mod and a second enable are refused (either would overwrite the originals in .backup)
out=$(ct --mod Q "$EXE" Better on 2>&1); [[ -f "$MD/Better/.enabled" ]] || fail "re-enable did not enable: $(print -r -- "$out" | grep -i mod)"
out=$(ct --addmod Q "$EXE" "$T/Better" 2>&1); [[ "$out" == *"Mod add refused"*"enabled"* && "$(cat "$MD/Better/.backup/data/a.txt")" == original ]] || fail "re-adding an enabled mod wiped its backup: $(print -r -- "$out" | grep -i mod) | backup=$(cat "$MD/Better/.backup/data/a.txt" 2>&1)"
out=$(ct --mod Q "$EXE" Better on 2>&1); [[ "$out" == *"already enabled"* && "$(cat "$MD/Better/.backup/data/a.txt")" == original ]] || fail "a second enable overwrote the backup"
ct --mod Q "$EXE" Better off >/dev/null 2>&1; [[ "$(cat "$G/data/a.txt")" == original ]] || fail "disable after the refused steps did not restore"
print "ok: re-adding an enabled mod and enabling twice are refused; the original survives"

# 5. the backup cannot be written (locked .backup folder): the original is not overwritten on enable, and not deleted on disable
mkdir -p "$T/Other/data"; print other > "$T/Other/data/a.txt"; ct --addmod Q "$EXE" "$T/Other" >/dev/null 2>&1
mkdir -p "$MD/Other/.backup/data"; chflags uchg "$MD/Other/.backup/data"
out=$(ct --mod Q "$EXE" Other on 2>&1)
[[ "$(cat "$G/data/a.txt")" == original && "$out" == *"with problems"* ]] || fail "enable overwrote an original it could not back up: $(print -r -- "$out" | grep -i mod)"
chflags nouchg "$MD/Other/.backup/data"; ct --mod Q "$EXE" Other off >/dev/null 2>&1
[[ "$(cat "$G/data/a.txt" 2>/dev/null)" == original ]] || fail "disable deleted the original that the enable had left alone"
print "ok: an original that could not be backed up is neither overwritten nor deleted later"

tw_check || fail "your real data changed"
print "PASS mod_safety"
