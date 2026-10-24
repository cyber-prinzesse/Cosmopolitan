// libFuzzer target for the two parsers that read untrusted executables. Needs Homebrew LLVM (Apple clang ships no libFuzzer runtime).
// The API takes a path, so each input is written to one temp file; both parsers must return without a sanitizer report.
#include "cosmo_native.h"
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>

static char path[64];
extern "C" int LLVMFuzzerInitialize(int *, char ***) { snprintf(path, sizeof path, "/private/tmp/cosmo-fuzz-%d.exe", getpid()); return 0; }
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 0;
    if (n && write(fd, d, n) != ssize_t(n)) { close(fd); return 0; }
    close(fd);
    char imps[2048], dely[2048];
    (void)cosmo_pe_read(path, imps, sizeof imps, dely, sizeof dely);
    (void)cosmo_avx_scan(path);
    return 0;
}
