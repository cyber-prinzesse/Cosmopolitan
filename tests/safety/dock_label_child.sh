#!/bin/zsh
# A program another program starts (Steam → REDlauncher) must get its own Dock label. Wine 10's ntdll overwrites
# WINELOADER with <bin>/<basename of argv[0]> for every child, so cosmo_wineloader passes itself as argv[0]; without that
# every child ran from its parent's loader copy and kept the parent's name (1.3.23). Stand-ins: HostApp.exe starts notepad.
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
fail() { print "FAIL: $*"; twineserver K -k 2>/dev/null; exit 1; }   # stop the bottle first so EXIT cleanup is quick
tw_snapshot
ct --newbottle K >/dev/null 2>&1; [[ -d "$(tprefix K)/drive_c" ]] || fail "throwaway bottle not created"
PF="$(tprefix K)/drive_c/Program Files/HostApp"; mkdir -p "$PF"
cat > "$T/host.c" <<'C'
#include <windows.h>
int main(void){ STARTUPINFOA si={sizeof si}; PROCESS_INFORMATION pi;
  CreateProcessA(NULL,"C:\\windows\\system32\\notepad.exe",NULL,NULL,FALSE,0,NULL,NULL,&si,&pi);
  Sleep(25000); return 0; }
C
x86_64-w64-mingw32-gcc -O2 -s "$T/host.c" -o "$PF/HostApp.exe" || fail "could not build HostApp"
# Names via the Mac Driver AppName (the scan rewrites options/dock-names.txt from the Steam library).
for e n in hostapp.exe "Host Name" notepad.exe "Child Name"; do
  twine K reg add "HKCU\\Software\\Wine\\AppDefaults\\$e\\Mac Driver" /v AppName /d "$n" /f >/dev/null 2>&1
done; twineserver K -w
ct --launch K "$PF/HostApp.exe" --wait 2 > "$T/l.out" 2>&1 &
child() { ps -axo pid=,command= | awk '$2 ~ /^C:.windows.system32.notepad.exe/{print $1; exit}'; }
for i in {1..40}; do sleep 1; n=$(child); [[ -n "$n" ]] && break; done
[[ -n "$n" ]] || fail "HostApp did not start notepad: $(tail -5 "$T/l.out")"
sleep 4
file() { python3 -I -c 'import ctypes,sys;l=ctypes.CDLL(None);b=ctypes.create_string_buffer(4096);l.proc_pidpath(int(sys.argv[1]),b,4096);print(b.value.decode().rsplit("/",1)[-1])' $1; }
f=$(file $n); [[ "${f//$'\u00a0'/ }" == "Child Name" ]] || fail "child runs from '$f', want 'Child Name' (parent's loader leaked to the child)"
for i in {1..20}; do d=$(osascript -e 'tell application "System Events" to get name of every UI element of list 1 of application process "Dock"' 2>&1); d=${d//$'\u00a0'/ }; [[ "$d" == *"Child Name"* ]] && break; sleep 0.5; done
[[ "$d" == *"Child Name"* ]] || fail "the Dock does not show 'Child Name': $d"
print "ok: notepad started by HostApp runs as 'Child Name' and the Dock shows it"
twineserver K -k
tw_check
print "PASS dock_label_child"
