// Native module tests, run under AddressSanitizer + UndefinedBehaviorSanitizer by tests/native/run.sh: real executables parse; every
// truncation of them and a set of malformed headers return cleanly; an exception inside each boundary function comes back as an error
// code instead of terminating the process (this build has COSMO_TEST_HOOKS).
#include "cosmo_native.h"
#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <cstring>
#include <fstream>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
#include <string>
#include <vector>

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static std::vector<uint8_t> slurp(const char *p) { std::ifstream f(p, std::ios::binary); return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), {}); }
static void spit(const std::string &p, const uint8_t *d, size_t n) { std::ofstream f(p, std::ios::binary | std::ios::trunc); f.write(reinterpret_cast<const char *>(d), std::streamsize(n)); }
static uint32_t le32(const std::vector<uint8_t> &d, size_t o) { return uint32_t(d[o]) | uint32_t(d[o + 1]) << 8 | uint32_t(d[o + 2]) << 16 | uint32_t(d[o + 3]) << 24; }
static void put32(std::vector<uint8_t> &d, size_t o, uint32_t v) { for (int i = 0; i < 4; i++) d[o + i] = uint8_t(v >> (8 * i)); }

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: pe_test fx64.exe fx32.exe tmpdir fxdelay.exe\n"); return 2; }
    const std::string tmp = argv[3], t = tmp + "/t.exe";
    char imps[4096], dely[4096];

    // 1. Real executables
    cosmo_pe_info r = cosmo_pe_read(argv[1], imps, sizeof imps, dely, sizeof dely);
    CHECK(r.error == 0 && r.kind == 3 && r.machine == 0x8664, "x64 fixture: error %d kind %d machine %x", r.error, r.kind, r.machine);
    CHECK(strstr(imps, "d3d9.dll") && strstr(imps, "user32.dll") && strstr(imps, "kernel32.dll"), "x64 imports: %s", imps);
    r = cosmo_pe_read(argv[2], imps, sizeof imps, dely, sizeof dely);
    CHECK(r.error == 0 && r.kind == 3 && r.machine == 0x14c && strstr(imps, "d3d9.dll"), "x86 fixture: error %d machine %x imports %s", r.error, r.machine, imps);
    cosmo_avx_result a = cosmo_avx_scan(argv[1]);
    CHECK(a.error == 0 && a.instructions > 0, "avx scan of x64 fixture: error %d instructions %llu", a.error, (unsigned long long)a.instructions);
    CHECK(cosmo_avx_scan(argv[2]).error == 3, "avx scan of x86 fixture should say not x86-64");
    r = cosmo_pe_read("/nonexistent/x.exe", imps, sizeof imps, dely, sizeof dely);
    CHECK(r.error == 1, "missing file: error %d", r.error);

    // Delay-load split (Epic "Won't run" false positive fix): a delay-loaded DLL lands in the delay list, never in the normal import list,
    // so the launch check can treat it as optional. The fixture delay-loads d3d9.dll and imports user32.dll normally as the control.
    r = cosmo_pe_read(argv[4], imps, sizeof imps, dely, sizeof dely);
    CHECK(r.error == 0 && r.delay_imports >= 1, "delay fixture: error %d delay_imports %u", r.error, r.delay_imports);
    CHECK(strstr(dely, "d3d9.dll"), "delay fixture: d3d9.dll should be in the delay list, got '%s'", dely);
    CHECK(!strstr(imps, "d3d9.dll"), "delay fixture: d3d9.dll must NOT be in the normal list (would be a false 'missing DLL'), got '%s'", imps);
    CHECK(strstr(imps, "user32.dll") && strstr(imps, "kernel32.dll"), "delay fixture: normal imports stay in the normal list, got '%s'", imps);

    // 2. The Phase 0 regression: 69 bytes, MZ + e_lfanew 0x40 + "PE\0\0" + 1 byte (read past the end before the fix)
    uint8_t p0[0x45] = {}; p0[0] = 'M'; p0[1] = 'Z'; p0[0x3C] = 0x40; memcpy(p0 + 0x40, "PE\0\0", 4);
    spit(t, p0, sizeof p0); r = cosmo_pe_read(t.c_str(), imps, sizeof imps, dely, sizeof dely);
    CHECK(r.error == 2, "69-byte truncated PE: error %d (want 2)", r.error);
    { const auto d = slurp(argv[1]); spit(t, d.data(), 2000); r = cosmo_pe_read(t.c_str(), imps, sizeof imps, dely, sizeof dely);   // headers intact, sections cut off
      CHECK(d.size() < 8192 || r.error == 2, "cut to 2000 of %zu bytes (inside its sections): error %d (want 2)", d.size(), r.error); }

    // 3. Every truncation: byte by byte through the first 4 KB, then every 4 KB
    size_t runs = 0;
    for (const char *fx : { argv[1], argv[2] }) {
        const auto d = slurp(fx);
        for (size_t len = 0; len <= d.size(); len += (len < 4096 ? 1 : 4096), runs++) {
            spit(t, d.data(), len);
            r = cosmo_pe_read(t.c_str(), imps, sizeof imps, dely, sizeof dely);
            CHECK(r.error != 3, "truncated to %zu: internal error", len);
            CHECK(r.error == 0 || r.error == 2, "truncated to %zu: unexpected error %d", len, r.error);
            CHECK(strlen(imps) < sizeof imps, "truncated to %zu: imports not terminated", len);
            CHECK(cosmo_avx_scan(t.c_str()).error != 4, "avx, truncated to %zu: internal error", len);
        }
    }

    // 4. Malformed headers built from the x64 fixture
    const auto base = slurp(argv[1]);
    const uint32_t h = le32(base, 0x3C);
    auto variant = [&](const char *what, auto patch) {
        auto d = base; patch(d); spit(t, d.data(), d.size());
        r = cosmo_pe_read(t.c_str(), imps, sizeof imps, dely, sizeof dely); a = cosmo_avx_scan(t.c_str());
        CHECK(r.error != 3 && a.error != 4, "%s: internal error (pe %d avx %d)", what, r.error, a.error);
        return r;
    };
    r = variant("e_lfanew past the end", [&](auto &d) { put32(d, 0x3C, 0xFFFFFFF0u); });
    CHECK(r.kind == 1 && r.error == 0, "e_lfanew past the end: kind %d error %d (want DOS)", r.kind, r.error);
    variant("65535 sections", [&](auto &d) { d[h + 6] = 0xFF; d[h + 7] = 0xFF; });
    variant("huge optional header size", [&](auto &d) { d[h + 20] = 0xFF; d[h + 21] = 0xFF; });
    variant("import RVA 0xFFFFFFF0", [&](auto &d) { put32(d, h + 24 + 112 + 8, 0xFFFFFFF0u); });
    variant("section raw pointer past the end", [&](auto &d) { const size_t s = h + 24 + (d[h + 20] | d[h + 21] << 8); put32(d, s + 20, 0x7FFFFFF0u); });
    variant("NumberOfRvaAndSizes 0xFFFFFFFF", [&](auto &d) { put32(d, h + 24 + 108, 0xFFFFFFFFu); });
    {   // a name that runs to the end of the file with no terminator
        auto d = base; d.resize(d.size() + 300, 'A'); spit(t, d.data(), d.size());
        r = cosmo_pe_read(t.c_str(), imps, sizeof imps, dely, sizeof dely); CHECK(r.error != 3, "unterminated trailing data: internal error");
    }

    // 5. An exception inside every boundary function comes back as an error code
    setenv("COSMO_NATIVE_TEST_THROW", "1", 1);
    strcpy(imps, "garbage");
    r = cosmo_pe_read(argv[1], imps, sizeof imps, dely, sizeof dely); CHECK(r.error == 3 && imps[0] == 0, "pe_read with a throw inside: error %d imports '%s'", r.error, imps);
    CHECK(cosmo_avx_scan(argv[1]).error == 4, "avx_scan with a throw inside");
    char out[64] = "garbage"; CHECK(cosmo_controllers(out, sizeof out) == 0 && out[0] == 0, "controllers with a throw inside");
    CHECK(cosmo_on_battery() == -1, "on_battery with a throw inside");
    int32_t pids[4]; CHECK(cosmo_proc_find("launchd", pids, 4) == 0, "proc_find with a throw inside");
    CHECK(cosmo_proc_find_in("launchd", "/", pids, 4) == 0, "proc_find_in with a throw inside");
    unsetenv("COSMO_NATIVE_TEST_THROW");
    pid_t child; char *sl[] = { const_cast<char *>("/bin/sleep"), const_cast<char *>("3"), nullptr };
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa); posix_spawn_file_actions_addchdir(&fa, "/private/tmp");
    if (posix_spawn(&child, "/bin/sleep", &fa, nullptr, sl, environ) == 0) {
        CHECK(cosmo_proc_find("/bin/sleep", pids, 4) > 0, "proc_find finds our own /bin/sleep child normally");
        CHECK(cosmo_proc_find_in("/bin/sleep", "/private/tmp", pids, 4) > 0, "proc_find_in finds the child by its working folder");
        CHECK(cosmo_proc_find_in("/bin/sleep", "/private/tm", pids, 4) == 0, "proc_find_in matches whole folder names only");
        CHECK(cosmo_proc_find_in("/bin/sleep", "/usr/share", pids, 4) == 0, "proc_find_in skips processes working elsewhere");
        kill(child, SIGTERM); waitpid(child, nullptr, 0);
    }
    const int b = cosmo_on_battery(); CHECK(b >= -1 && b <= 1, "on_battery range %d", b);

    if (failures) printf("native tests: %d FAILED\n", failures);
    else printf("native tests: all passed (%zu truncations, 7 malformed headers, 6 boundary throws)\n", runs);
    return failures != 0;
}
