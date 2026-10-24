// PE (Windows executable) facts read natively: kind (dos / win16 / pe), machine, subsystem and linker versions, and the import table
// including delay-load imports. The input is untrusted (any file in a bottle): every read goes through File::read, which checks offset
// and length against the file size; work is capped (96 sections, 4096 import descriptors per table, 256-byte names); nothing throws
// across the C boundary. A truncated or malformed header gives error 2 instead of a guess.
#include "cosmo_native.h"
#include "native_file.h"
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <new>
#include <set>
#include <string>
#include <vector>

namespace {
struct Section { uint32_t va, vsize, rawsize, rawptr; };

void pe_read(const char *path, cosmo_pe_info &r, std::string &list, std::string &delaylist) {
#ifdef COSMO_TEST_HOOKS
    if (getenv("COSMO_NATIVE_TEST_THROW")) throw std::bad_alloc();
#endif
    cosmo::File f(path);
    if (!f.ok()) { r.error = 1; return; }
    uint8_t mz[2];
    if (!f.read(0, mz, 2)) { r.error = 2; return; }                         // shorter than a signature
    if (mz[0] != 'M' || mz[1] != 'Z') return;                                // not an executable (kind 0, no error)
    uint32_t h;
    if (!f.u32(0x3C, h)) { r.error = 2; return; }                            // MZ but truncated before e_lfanew
    uint8_t sig[4];
    if (!f.read(h, sig, 4)) { r.kind = 1; return; }                          // no new header: plain DOS program
    if (sig[0] == 'N' && sig[1] == 'E') { r.kind = 2; return; }              // Win16
    if (memcmp(sig, "PE\0\0", 4) != 0) { r.kind = 1; return; }
    r.kind = 3;
    uint32_t machine, nsec, optsize, magic, subsys;
    uint8_t linker;
    const uint64_t opt = uint64_t(h) + 24;
    if (!f.u16(uint64_t(h) + 4, machine) || !f.u16(uint64_t(h) + 6, nsec) || !f.u16(uint64_t(h) + 20, optsize) ||
        !f.u16(opt, magic) || !f.read(opt + 2, &linker, 1) || !f.u16(opt + 48, subsys)) { r.error = 2; return; }
    r.machine = uint16_t(machine); r.linker_major = linker; r.subsystem_major = uint16_t(subsys);
    const bool plus = magic == 0x20b;
    std::vector<Section> secs;
    for (uint32_t i = 0; i < std::min<uint32_t>(nsec, 96); i++) {
        uint8_t b[40];
        if (!f.read(opt + optsize + uint64_t(i) * 40, b, sizeof b)) break;
        auto le = [&](int o) { return uint32_t(b[o]) | uint32_t(b[o + 1]) << 8 | uint32_t(b[o + 2]) << 16 | uint32_t(b[o + 3]) << 24; };
        secs.push_back({ le(12), le(8), le(16), le(20) });
    }
    // Cut inside its sections = truncated, not "a program without imports": a section table that ends early, or raw data ending more
    // than a page past the end of the file (one page of slack: some linkers round the last section's size up past the end).
    if (secs.size() < std::min<uint32_t>(nsec, 96)) { r.error = 2; return; }
    for (const auto &s : secs) if (s.rawsize && uint64_t(s.rawptr) + s.rawsize > f.size() + 4096) { r.error = 2; return; }
    auto off = [&](uint32_t rva, uint64_t &o) {   // RVA → file offset, only inside a section and inside the file
        for (const auto &s : secs) {
            const uint32_t sz = std::max(s.vsize, s.rawsize);
            if (rva >= s.va && rva - s.va < sz) { o = uint64_t(s.rawptr) + (rva - s.va); return o < f.size(); }
        }
        return false;
    };
    std::set<std::string> seen;
    auto add = [&](std::string &target, uint32_t nameRva) {
        uint64_t o;
        if (!off(nameRva, o)) return;
        char buf[257] = {};
        const size_t n = size_t(std::min<uint64_t>(256, f.size() - o));
        if (!f.read(o, buf, n)) return;
        std::string s(buf, strnlen(buf, n));
        for (auto &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
        if (s.empty() || !seen.insert(s).second) return;
        if (!target.empty()) target += ',';
        target += s;
    };
    const uint64_t dd = opt + (plus ? 112 : 96);
    uint32_t ndirs = 0;
    if (!f.u32(opt + (plus ? 108 : 92), ndirs)) { r.error = 2; return; }
    uint32_t rva, name;
    uint64_t o;
    if (ndirs > 1 && f.u32(dd + 8, rva) && rva && off(rva, o))                 // import directory: 20-byte descriptors, name RVA at +12
        for (uint32_t i = 0; i < 4096 && f.u32(o + uint64_t(i) * 20 + 12, name) && name; i++) add(list, name);
    if (ndirs > 14 && f.u32(dd + 14 * 8, rva) && rva) r.clr = 1;                // CLR (.NET) header directory
    if (ndirs > 13 && f.u32(dd + 13 * 8, rva) && rva && off(rva, o))           // delay-load directory: 32-byte descriptors, name RVA at +4
        for (uint32_t i = 0; i < 4096 && f.u32(o + uint64_t(i) * 32 + 4, name) && name; i++) { add(delaylist, name); r.delay_imports++; }
}
} // namespace

extern "C" cosmo_pe_info cosmo_pe_read(const char *path, char *imports, size_t cap, char *delay, size_t delaycap) noexcept {
    cosmo_pe_info r{};
    if (imports && cap) imports[0] = 0;
    if (delay && delaycap) delay[0] = 0;
    if (!path) { r.error = 1; return r; }
    try {
        std::string list, delaylist;
        pe_read(path, r, list, delaylist);
        if (imports && cap) { const size_t n = std::min(list.size(), cap - 1); memcpy(imports, list.data(), n); imports[n] = 0; }
        if (delay && delaycap) { const size_t n = std::min(delaylist.size(), delaycap - 1); memcpy(delay, delaylist.data(), n); delay[n] = 0; }
    } catch (...) {   // nothing may escape into Swift (it can't catch C++ exceptions); report it instead
        r = cosmo_pe_info{}; r.error = 3;
        if (imports && cap) imports[0] = 0;
    }
    return r;
}
