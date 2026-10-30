#!/bin/zsh
# Rebuilds Resources/netprobe.exe from Resources/netprobe.cs with Wine Mono's own C# compiler, in a throwaway prefix that gets the
# pinned WineHQ Wine Mono MSI (from the app's download cache, or WineHQ).
source "${0:A:h}/../lib/testenv.sh"; testenv_init >/dev/null || exit 1; eval "$(testenv_trap_cleanup)"
ct --newbottle M >/dev/null 2>&1; P="$(tprefix M)"
[[ -d "$P/drive_c/windows/mono" ]] || { print "Wine Mono missing in the new bottle"; exit 1; }
mcs=$(cd "$P/drive_c" && find windows/mono -iname mcs.exe | head -1)
cp "$TESTENV_REPO/Resources/netprobe.cs" "$P/drive_c/windows/temp/" && (cd "$P/drive_c/windows/temp" && twine M "C:\\${mcs//\//\\}" -nologo -target:exe -out:netprobe.exe netprobe.cs) || exit 1
cp "$P/drive_c/windows/temp/netprobe.exe" "$TESTENV_REPO/Resources/" && shasum -a 256 "$TESTENV_REPO/Resources/netprobe.exe"
