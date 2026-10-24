#!/bin/zsh
# Native (C++) tests. Fixtures are tiny Windows programs built with mingw; the unit tests run under AddressSanitizer + UndefinedBehavior-
# Sanitizer (Apple clang); then libFuzzer runs the PE parser and AVX scanner for a fixed time (Homebrew LLVM). Any report fails the run.
# Usage: tests/native/run.sh [fuzz seconds, default 60]
set -e
cd "${0:A:h}"; N=../../Sources/Native; O="$(mktemp -d /private/tmp/cosmo-native.XXXXXX)"; trap 'rm -rf "$O"; rm -f /private/tmp/cosmo-fuzz-*.exe(N)' EXIT
printf '#include <windows.h>\n#include <d3d9.h>\nint main(void) { Direct3DCreate9(D3D_SDK_VERSION); MessageBoxA(0, "", "", 0); return 0; }\n' > "$O/fx.c"
x86_64-w64-mingw32-gcc -O1 "$O/fx.c" -o "$O/fx64.exe" -ld3d9 -luser32
i686-w64-mingw32-gcc -O1 "$O/fx.c" -o "$O/fx32.exe" -ld3d9 -luser32
# A delay-load fixture for the import split (Epic "Won't run" false positive): d3d9 delay-loaded via a dlltool delay lib, user32 normal.
printf 'LIBRARY d3d9.dll\nEXPORTS\nDirect3DCreate9\n' > "$O/d3d9.def"
x86_64-w64-mingw32-dlltool -d "$O/d3d9.def" -y "$O/libd3d9delay.a"
x86_64-w64-mingw32-gcc -O1 "$O/fx.c" -o "$O/fxdelay.exe" "$O/libd3d9delay.a" -luser32
SAN=(-fsanitize=address,undefined -fno-sanitize-recover=all -g -O1)
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -DCOSMO_TEST_HOOKS "${SAN[@]}" -I$N $N/pe.cpp $N/avxscan.cpp $N/sysinfo.cpp pe_test.cpp \
  -framework IOKit -framework CoreFoundation -o "$O/pe_test"
"$O/pe_test" "$O/fx64.exe" "$O/fx32.exe" "$O" "$O/fxdelay.exe"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -DCOSMO_TEST_HOOKS "${SAN[@]}" -I$N $N/decide.cpp decide_test.cpp -o "$O/decide_test"
"$O/decide_test"
LLVM=/opt/homebrew/opt/llvm/bin/clang++
[[ -x $LLVM ]] || { print "fuzzing skipped: Homebrew LLVM not installed (brew install llvm)"; exit 1; }
mkdir -p "$O/corpus"; cp "$O/fx64.exe" "$O/fx32.exe" "$O/fxdelay.exe" "$O/corpus/"
$LLVM -std=c++17 -isysroot "$(xcrun --show-sdk-path)" "${SAN[@]}" -fsanitize=fuzzer -I$N $N/pe.cpp $N/avxscan.cpp fuzz_pe.cpp -o "$O/fuzz_pe"
"$O/fuzz_pe" -max_total_time=${1:-60} -rss_limit_mb=2048 -print_final_stats=1 "$O/corpus" > "$O/fuzz.log" 2>&1 || { tail -30 "$O/fuzz.log"; print "FUZZ FAILED"; exit 1; }
print "fuzz: $(grep -o 'stat::number_of_executed_units: *[0-9]*' "$O/fuzz.log" | grep -o '[0-9]*$') inputs in ${1:-60} s, no sanitizer report ($(grep -o 'cov: [0-9]*' "$O/fuzz.log" | tail -1))"
