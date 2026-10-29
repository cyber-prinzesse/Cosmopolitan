// The compatibility decision table (docs/design/compat-gate.md §3.6), first matching row wins:
//  1 kernel anti-cheat → block · 2 Rosetta can't run x86 → block · 3 needs AVX2, the AVX2 probe failed → block · 4 AVX-512 paths → warning
//  5 no backend can serve the game's main API → incompatible, ranked alternatives · 6 per-game pin can serve → use it
//  7 per-game pin can't serve → ask, with the best other choice · 8 DB known-good backend can serve → use it
//  9 DB known-good backend's installed version crashed this game here → ask: roll back side by side · 10 capability heuristic → use
//  11 global default, when it is among the capable backends → use it. Precedence: blockers > per-game pin > DB > heuristic > global default.
//  12 (cosmo_fallback, after a crash within 30 s) next of DXMT → D3DMetal → DXVK → vkd3d-proton that serves the main API and hasn't failed here → use it;
//     the user's own pin crashed → ask with that proposal; none left → incompatible. The caller retries once, never more.
// Pre-flight (cosmo_preflight, item 28): Direct3D/DirectDraw imports → API bits; a .NET header or mscoree.dll → Wine Mono; a Visual C++
// 2015–2022 DLL → that runtime in the program's bitness; a DirectX June 2010 DLL (d3dx*, xaudio2_*, xinput1_*, …) → DirectX.
// Anti-cheat (cosmo_anticheat, item 29), first match wins: kernel anti-cheat → block · AreWeAntiCheatYet "Denied" (the developer refuses
// Wine/Proton) → block · "Broken" → block · EAC/BattlEye found, or "Supported"/"Running"/"Planned" → ask: online play likely fails on a
// Mac, whose Wine has no anti-cheat runtime even where Proton does · nothing known → use.
// Pure: plain values in, plain values out; no I/O, no globals; nothing throws across the boundary.
#include "cosmo_native.h"
#include <cstdlib>
#include <initializer_list>
#include <new>
#include <cstring>
#include <string>

namespace {
uint32_t mainApi(uint32_t apis) { for (uint32_t b = COSMO_API_D3D12; b; b >>= 1) if (apis & b) return b; return 0; }
// Preference per API when nothing else decides (DXVK's D3D9 is the 2.3 build; DXVK 3 never qualifies because serves[] reflects capabilities).
int prefs(uint32_t api, int out[4]) {
    static const int d12[] = { COSMO_BE_D3DMETAL, COSMO_BE_VKD3D_PROTON }, d11[] = { COSMO_BE_DXMT, COSMO_BE_DXVK, COSMO_BE_D3DMETAL, COSMO_BE_WINED3D },
                     d10[] = { COSMO_BE_DXMT, COSMO_BE_DXVK, COSMO_BE_WINED3D }, d9[] = { COSMO_BE_DXVK, COSMO_BE_WINED3D }, dd[] = { COSMO_BE_CNC_DDRAW, COSMO_BE_WINED3D };
    const int *p = d9; int n = 2;
    switch (api) { case COSMO_API_D3D12: p = d12; n = 2; break; case COSMO_API_D3D11: p = d11; n = 4; break; case COSMO_API_D3D10: p = d10; n = 3; break;
                   case COSMO_API_DDRAW: p = dd; n = 2; break; default: break; }
    for (int i = 0; i < n; i++) out[i] = p[i];
    return n;
}
bool valid(int b) { return b > COSMO_BE_NONE && b < COSMO_BE_COUNT; }

cosmo_decision decide(const cosmo_decision_input &in) {
#ifdef COSMO_TEST_HOOKS
    if (getenv("COSMO_NATIVE_TEST_THROW")) throw std::bad_alloc();
#endif
    cosmo_decision d{};
    if ((in.ram_gb && in.ram_gb <= 8) || (in.game_min_ram_gb && in.game_min_ram_gb > in.ram_gb)) d.warnings |= COSMO_WARN_RAM;
    if (in.rt_on_in_game && in.gpu_family < 9) d.warnings |= COSMO_WARN_RT_NO_HARDWARE;
    if (in.avx512_paths) d.warnings |= COSMO_WARN_AVX512;                                                    // row 4: a warning, not a verdict
    auto set = [&](int verdict, int row, int backend) { d.verdict = verdict; d.row = row; d.backend = backend; return d; };
    auto option = [&](int b, bool avail) { if (d.noptions < 4) { d.options[d.noptions] = b; d.option_available[d.noptions] = avail; d.noptions++; } };
    if (in.kernel_anticheat) return set(COSMO_BLOCK, 1, COSMO_BE_NONE);
    if (!in.rosetta_ok) return set(COSMO_BLOCK, 2, COSMO_BE_NONE);
    if (in.needs_avx2 && !in.rosetta_avx2_ok) return set(COSMO_BLOCK, 3, COSMO_BE_NONE);
    const uint32_t api = mainApi(in.apis);
    if (!api) return set(COSMO_USE, 10, COSMO_BE_NONE);                                                      // not a graphics program
    auto can = [&](int b) { return valid(b) && (in.serves[b] & api) && !in.failed_here[b]; };
    int order[4]; const int n = prefs(api, order);
    int heuristic = COSMO_BE_NONE;
    for (int i = 0; i < n && heuristic == COSMO_BE_NONE; i++) if (can(order[i])) heuristic = order[i];
    bool anyServes = false;
    for (int b = 1; b < COSMO_BE_COUNT; b++) if (in.serves[b] & api) anyServes = true;
    if (!anyServes) {                                                                                        // row 5: hard incompatibility
        if (valid(in.db_known_good) && (in.implements[in.db_known_good] & api)) option(in.db_known_good, false);
        for (int rank : { COSMO_DB_KNOWN_GOOD, COSMO_DB_UNKNOWN, COSMO_DB_EXPERIMENTAL, COSMO_DB_BROKEN })
            for (int b = 1; b < COSMO_BE_COUNT; b++)
                if ((in.implements[b] & api) && in.db_status[b] == rank && b != in.db_known_good && d.noptions < 3) option(b, false);
        option(COSMO_BE_NONE, true);
        return set(COSMO_INCOMPATIBLE, 5, d.noptions > 1 ? d.options[0] : COSMO_BE_NONE);
    }
    if (valid(in.game_pin)) {
        if (can(in.game_pin)) return set(COSMO_USE, 6, in.game_pin);
        const int proposal = can(in.db_known_good) ? in.db_known_good : heuristic;                           // row 7: never override silently
        option(proposal, proposal != COSMO_BE_NONE); option(in.game_pin, false); option(COSMO_BE_NONE, true);
        return set(COSMO_ASK, 7, proposal);
    }
    if (can(in.db_known_good)) return set(COSMO_USE, 8, in.db_known_good);
    if (valid(in.db_known_good) && (in.serves[in.db_known_good] & api) && in.failed_here[in.db_known_good]) {   // row 9
        option(in.db_known_good, true); if (heuristic != COSMO_BE_NONE) option(heuristic, true); option(COSMO_BE_NONE, true);
        return set(COSMO_ASK, 9, in.db_known_good);
    }
    if (valid(in.global_pin) && can(in.global_pin)) return set(COSMO_USE, 11, in.global_pin);                 // global default among the capable
    if (heuristic != COSMO_BE_NONE) return set(COSMO_USE, 10, heuristic);
    for (int b = 1; b < COSMO_BE_COUNT; b++) if (in.serves[b] & api) option(b, true);                       // every capable one failed here
    option(COSMO_BE_NONE, true);
    return set(COSMO_ASK, 9, d.options[0]);
}
cosmo_decision fallback(const cosmo_decision_input &in, int crashed) {
#ifdef COSMO_TEST_HOOKS
    if (getenv("COSMO_NATIVE_TEST_THROW")) throw std::bad_alloc();
#endif
    cosmo_decision d{}; d.row = 12; d.verdict = COSMO_INCOMPATIBLE; d.backend = COSMO_BE_NONE;
    static const int chain[] = { COSMO_BE_DXMT, COSMO_BE_D3DMETAL, COSMO_BE_DXVK, COSMO_BE_VKD3D_PROTON };
    const uint32_t api = mainApi(in.apis);
    int from = 0; for (int i = 0; i < 4; i++) if (chain[i] == crashed) from = i + 1;
    for (int i = from; i < 4; i++) {
        const int b = chain[i];
        if (b != crashed && (in.serves[b] & api) && !in.failed_here[b]) { d.verdict = in.game_pin == crashed ? COSMO_ASK : COSMO_USE; d.backend = b; break; }
    }
    if (d.verdict == COSMO_ASK) { d.options[0] = d.backend; d.option_available[0] = 1; d.options[1] = COSMO_BE_NONE; d.option_available[1] = 1; d.noptions = 2; }
    return d;
}
cosmo_preflight_result preflight(const char *csv, bool is32, bool clr) {
#ifdef COSMO_TEST_HOOKS
    if (getenv("COSMO_NATIVE_TEST_THROW")) throw std::bad_alloc();
#endif
    static const char *const vc[] = { "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll",
        "vcruntime140.dll", "vcruntime140_1.dll", "concrt140.dll", "vccorlib140.dll", "mfc140.dll", "mfc140u.dll", "vcomp140.dll", "vcamp140.dll" };
    static const char *const dx[] = { "d3dx9_", "d3dx10", "d3dx11_", "xaudio2_", "x3daudio1_", "xactengine", "xapofx1_", "xinput1_", "d3dcompiler_3",
        "d3dcompiler_40", "d3dcompiler_41", "d3dcompiler_42", "d3dcompiler_43" };
    static const struct { const char *dll; uint32_t api; } gfx[] = { { "d3d12.dll", COSMO_API_D3D12 }, { "d3d11.dll", COSMO_API_D3D11 },
        { "d3d10.dll", COSMO_API_D3D10 }, { "d3d10_1.dll", COSMO_API_D3D10 }, { "d3d10core.dll", COSMO_API_D3D10 }, { "d3d9.dll", COSMO_API_D3D9 },
        { "d3d8.dll", COSMO_API_D3D8 }, { "ddraw.dll", COSMO_API_DDRAW } };
    cosmo_preflight_result r{};
    if (clr) r.needs |= COSMO_NEED_DOTNET;
    std::string all(csv);
    for (size_t a = 0; a <= all.size();) {   // comma-separated, lower-case names
        size_t b = all.find(',', a); if (b == std::string::npos) b = all.size();
        const std::string n = all.substr(a, b - a); a = b + 1;
        if (n.empty()) continue;
        if (n == "mscoree.dll") r.needs |= COSMO_NEED_DOTNET;
        for (const char *v : vc) if (n == v) r.needs |= is32 ? COSMO_NEED_VCREDIST86 : COSMO_NEED_VCREDIST64;
        for (const char *p : dx) if (n.compare(0, strlen(p), p) == 0) r.needs |= COSMO_NEED_DIRECTX;
        for (const auto &g : gfx) if (n == g.dll) r.apis |= g.api;
    }
    return r;
}
cosmo_ac_result anticheat(uint32_t found, int awacy) {
#ifdef COSMO_TEST_HOOKS
    if (getenv("COSMO_NATIVE_TEST_THROW")) throw std::bad_alloc();
#endif
    cosmo_ac_result r{};
    auto set = [&](int v, int why) { r.verdict = v; r.reason = why; return r; };
    if (found & COSMO_AC_KERNEL) return set(COSMO_BLOCK, COSMO_ACR_KERNEL);
    if (awacy == COSMO_AWACY_DENIED) return set(COSMO_BLOCK, COSMO_ACR_DENIED);
    if (awacy == COSMO_AWACY_BROKEN) return set(COSMO_BLOCK, COSMO_ACR_BROKEN);
    if ((found & (COSMO_AC_EAC | COSMO_AC_BATTLEYE)) || awacy == COSMO_AWACY_SUPPORTED || awacy == COSMO_AWACY_RUNNING || awacy == COSMO_AWACY_PLANNED)
        return set(COSMO_ASK, COSMO_ACR_ONLINE);
    return set(COSMO_USE, COSMO_ACR_NONE);
}
} // namespace

extern "C" cosmo_ac_result cosmo_anticheat(uint32_t found, int32_t awacy) noexcept {
    try { return anticheat(found, awacy); } catch (...) { cosmo_ac_result r{}; r.error = 2; return r; }
}
extern "C" cosmo_preflight_result cosmo_preflight(const char *imports_csv, int32_t is32, int32_t clr) noexcept {
    cosmo_preflight_result r{};
    if (!imports_csv) { r.error = 1; return r; }
    try { return preflight(imports_csv, is32 != 0, clr != 0); } catch (...) { r.error = 2; return r; }
}
extern "C" cosmo_decision cosmo_fallback(const cosmo_decision_input *in, int32_t crashed) noexcept {
    cosmo_decision d{}; d.row = 12;
    if (!in) { d.error = 1; return d; }
    try { return fallback(*in, crashed); } catch (...) { d.error = 2; return d; }
}
extern "C" cosmo_decision cosmo_decide(const cosmo_decision_input *in) noexcept {
    if (!in) { cosmo_decision d{}; d.error = 1; return d; }
    try { return decide(*in); }
    catch (...) { cosmo_decision d{}; d.error = 2; return d; }   // nothing may escape into Swift
}
