// Decision table tests (run under ASan + UBSan by tests/native/run.sh): one test per row of docs/design/compat-gate.md §3.6, the precedence
// rules, and conflict scenario A. Hosts are plain values, so M1…M5 and any macOS are tested on one Mac.
#include "cosmo_native.h"
#include <cstdio>
#include <cstdlib>

static int failures = 0, tests = 0;
#define CHECK(c, ...) do { if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)
#define TEST(name) static void name(); struct name##_r { name##_r() { tests++; name(); } } name##_i; static void name()

// An M2 Max with 32 GB and working Rosetta; a 64-bit D3D11 game; DXMT and DXVK serve D3D10/11, Wine's own serves the old APIs.
static cosmo_decision_input base() {
    cosmo_decision_input in{};
    in.apis = COSMO_API_D3D11; in.rosetta_ok = 1; in.rosetta_avx2_ok = 1; in.gpu_family = 8; in.ram_gb = 32;
    in.serves[COSMO_BE_DXMT] = COSMO_API_D3D10 | COSMO_API_D3D11;
    in.serves[COSMO_BE_DXVK] = COSMO_API_D3D9 | COSMO_API_D3D10 | COSMO_API_D3D11;
    in.serves[COSMO_BE_WINED3D] = COSMO_API_DDRAW | COSMO_API_D3D8 | COSMO_API_D3D9;
    for (int b = 1; b < COSMO_BE_COUNT; b++) in.implements[b] = in.serves[b];
    in.implements[COSMO_BE_D3DMETAL] = COSMO_API_D3D11 | COSMO_API_D3D12;
    in.implements[COSMO_BE_VKD3D_PROTON] = COSMO_API_D3D12;
    return in;
}
static cosmo_decision run(const cosmo_decision_input &in) { return cosmo_decide(&in); }

TEST(row1_kernel_anticheat_blocks_even_with_a_pin) { auto in = base(); in.kernel_anticheat = 1; in.game_pin = COSMO_BE_DXVK;
    auto d = run(in); CHECK(d.verdict == COSMO_BLOCK && d.row == 1, "verdict %d row %d", d.verdict, d.row); }
TEST(row2_no_rosetta_blocks) { auto in = base(); in.rosetta_ok = 0;
    auto d = run(in); CHECK(d.verdict == COSMO_BLOCK && d.row == 2, "verdict %d row %d", d.verdict, d.row); }
TEST(row3_avx2_needed_but_probe_failed_blocks) { auto in = base(); in.needs_avx2 = 1; in.rosetta_avx2_ok = 0;
    auto d = run(in); CHECK(d.verdict == COSMO_BLOCK && d.row == 3, "verdict %d row %d", d.verdict, d.row);
    in.rosetta_avx2_ok = 1; d = run(in); CHECK(d.verdict == COSMO_USE, "AVX2 game with a working probe should run (verdict %d)", d.verdict); }
TEST(row4_avx512_is_a_warning_only) { auto in = base(); in.avx512_paths = 1;
    auto d = run(in); CHECK(d.verdict == COSMO_USE && (d.warnings & COSMO_WARN_AVX512), "verdict %d warnings %x", d.verdict, d.warnings); }
TEST(row5_no_backend_for_the_main_api_is_incompatible) { auto in = base(); in.apis = COSMO_API_D3D12;
    auto d = run(in); CHECK(d.verdict == COSMO_INCOMPATIBLE && d.row == 5, "verdict %d row %d", d.verdict, d.row);
    CHECK(d.noptions >= 2 && d.options[d.noptions - 1] == COSMO_BE_NONE, "cancel must be the last option"); }
TEST(row6_game_pin_that_can_serve_is_used) { auto in = base(); in.game_pin = COSMO_BE_DXVK; in.db_known_good = COSMO_BE_DXMT;
    auto d = run(in); CHECK(d.verdict == COSMO_USE && d.row == 6 && d.backend == COSMO_BE_DXVK, "verdict %d row %d backend %d", d.verdict, d.row, d.backend); }
TEST(row7_game_pin_that_cannot_serve_asks_and_proposes) { auto in = base(); in.apis = COSMO_API_D3D12; in.game_pin = COSMO_BE_DXVK;
    in.serves[COSMO_BE_D3DMETAL] = COSMO_API_D3D11 | COSMO_API_D3D12;
    auto d = run(in); CHECK(d.verdict == COSMO_ASK && d.row == 7 && d.backend == COSMO_BE_D3DMETAL, "verdict %d row %d backend %d", d.verdict, d.row, d.backend);
    CHECK(d.options[0] == COSMO_BE_D3DMETAL && d.option_available[0] && d.options[1] == COSMO_BE_DXVK && !d.option_available[1], "options"); }
TEST(row8_db_known_good_beats_the_heuristic) { auto in = base(); in.db_known_good = COSMO_BE_DXVK;
    auto d = run(in); CHECK(d.verdict == COSMO_USE && d.row == 8 && d.backend == COSMO_BE_DXVK, "verdict %d row %d backend %d", d.verdict, d.row, d.backend); }
TEST(row9_known_good_version_regressed_here_asks_for_rollback) { auto in = base(); in.db_known_good = COSMO_BE_DXMT; in.failed_here[COSMO_BE_DXMT] = 1;
    auto d = run(in); CHECK(d.verdict == COSMO_ASK && d.row == 9 && d.backend == COSMO_BE_DXMT, "verdict %d row %d backend %d", d.verdict, d.row, d.backend);
    CHECK(d.noptions == 3 && d.options[1] == COSMO_BE_DXVK && d.options[2] == COSMO_BE_NONE, "rollback, next candidate, cancel"); }
TEST(row10_heuristic_follows_preference) { auto in = base();
    auto d = run(in); CHECK(d.verdict == COSMO_USE && d.row == 10 && d.backend == COSMO_BE_DXMT, "verdict %d row %d backend %d", d.verdict, d.row, d.backend);
    in.apis = COSMO_API_DDRAW; d = run(in); CHECK(d.backend == COSMO_BE_WINED3D, "DirectDraw without cnc-ddraw → Wine's own (%d)", d.backend);
    in.is32 = 1; in.serves[COSMO_BE_CNC_DDRAW] = COSMO_API_DDRAW; d = run(in); CHECK(d.backend == COSMO_BE_CNC_DDRAW, "32-bit DirectDraw → cnc-ddraw (%d)", d.backend); }
TEST(row11_global_default_picks_among_capable) { auto in = base(); in.global_pin = COSMO_BE_DXVK;
    auto d = run(in); CHECK(d.verdict == COSMO_USE && d.row == 11 && d.backend == COSMO_BE_DXVK, "verdict %d row %d backend %d", d.verdict, d.row, d.backend);
    in.apis = COSMO_API_DDRAW; d = run(in); CHECK(d.row == 10 && d.backend == COSMO_BE_WINED3D, "a global default that can't serve is skipped (row %d backend %d)", d.row, d.backend); }
TEST(precedence_pin_beats_db_and_db_beats_global) { auto in = base(); in.game_pin = COSMO_BE_DXMT; in.db_known_good = COSMO_BE_DXVK; in.global_pin = COSMO_BE_DXVK;
    CHECK(run(in).backend == COSMO_BE_DXMT, "per-game pin first");
    in.game_pin = COSMO_BE_NONE; in.db_known_good = COSMO_BE_DXMT; CHECK(run(in).row == 8 && run(in).backend == COSMO_BE_DXMT, "DB before global default"); }
TEST(dxvk3_style_backend_without_capabilities_is_never_chosen) { auto in = base(); in.apis = COSMO_API_D3D9;
    in.serves[COSMO_BE_DXVK] = 0;   // the probe says MoltenVK lacks DXVK 3's required features: serves nothing
    auto d = run(in); CHECK(d.backend == COSMO_BE_WINED3D, "D3D9 must fall back to Wine's own, got %d", d.backend); }
TEST(warnings_ram_and_ray_tracing) { auto in = base(); in.ram_gb = 8; in.rt_on_in_game = 1; in.gpu_family = 7;
    auto d = run(in); CHECK((d.warnings & COSMO_WARN_RAM) && (d.warnings & COSMO_WARN_RT_NO_HARDWARE), "warnings %x", d.warnings);
    in.ram_gb = 32; in.gpu_family = 9; CHECK(run(in).warnings == 0, "M3-class GPU with 32 GB: no warnings"); }
// Conflict scenario A: M1 Air 8 GB, macOS 15, D3D12 + AVX2 game, RT on after an update, global pin DXVK, DB says D3DMetal known-good but GPTK
// isn't installed, vkd3d-proton broken (and it can't run on stock MoltenVK anyway).
TEST(scenario_a) { auto in = base(); in.apis = COSMO_API_D3D12; in.needs_avx2 = 1; in.rosetta_avx2_ok = 1; in.gpu_family = 7; in.ram_gb = 8;
    in.rt_on_in_game = 1; in.global_pin = COSMO_BE_DXVK; in.db_known_good = COSMO_BE_D3DMETAL;
    in.db_status[COSMO_BE_D3DMETAL] = COSMO_DB_KNOWN_GOOD; in.db_status[COSMO_BE_VKD3D_PROTON] = COSMO_DB_BROKEN;
    auto d = run(in);
    CHECK(d.verdict == COSMO_INCOMPATIBLE && d.row == 5, "verdict %d row %d", d.verdict, d.row);
    CHECK(d.noptions == 3 && d.options[0] == COSMO_BE_D3DMETAL && d.options[1] == COSMO_BE_VKD3D_PROTON && d.options[2] == COSMO_BE_NONE,
          "ranked options %d %d %d (n %d)", d.options[0], d.options[1], d.options[2], d.noptions);
    CHECK(!d.option_available[0] && !d.option_available[1] && d.option_available[2], "GPTK not installed and vkd3d-proton unavailable are greyed out");
    CHECK((d.warnings & COSMO_WARN_RAM) && (d.warnings & COSMO_WARN_RT_NO_HARDWARE), "8 GB and ray tracing warnings %x", d.warnings);
    CHECK(in.global_pin == COSMO_BE_DXVK, "the global pin is input only and stays DXVK"); }
TEST(boundary_no_input_and_exceptions) { CHECK(cosmo_decide(nullptr).error == 1, "null input");
    setenv("COSMO_NATIVE_TEST_THROW", "1", 1); auto in = base(); auto d = cosmo_decide(&in); unsetenv("COSMO_NATIVE_TEST_THROW");
    CHECK(d.error == 2, "an exception inside must come back as error 2 (got %d)", d.error); }

// Row 12, driver fallback (item 27): after a crash within 30 s, the next of DXMT → D3DMetal → DXVK → vkd3d-proton; the user's own pin is asked about.
TEST(row12_dxmt_crash_falls_to_d3dmetal) { auto in = base(); in.serves[COSMO_BE_D3DMETAL] = COSMO_API_D3D11 | COSMO_API_D3D12;
    auto d = cosmo_fallback(&in, COSMO_BE_DXMT); CHECK(d.verdict == COSMO_USE && d.row == 12 && d.backend == COSMO_BE_D3DMETAL, "verdict %d row %d backend %d", d.verdict, d.row, d.backend); }
TEST(row12_skips_what_is_not_installed) { auto in = base();
    auto d = cosmo_fallback(&in, COSMO_BE_DXMT); CHECK(d.verdict == COSMO_USE && d.backend == COSMO_BE_DXVK, "no D3DMetal: verdict %d backend %d", d.verdict, d.backend); }
TEST(row12_skips_what_failed_here) { auto in = base(); in.serves[COSMO_BE_D3DMETAL] = COSMO_API_D3D11; in.failed_here[COSMO_BE_D3DMETAL] = 1;
    auto d = cosmo_fallback(&in, COSMO_BE_DXMT); CHECK(d.verdict == COSMO_USE && d.backend == COSMO_BE_DXVK, "D3DMetal failed here: backend %d", d.backend); }
TEST(row12_end_of_chain) { auto in = base(); in.serves[COSMO_BE_D3DMETAL] = COSMO_API_D3D11;
    auto d = cosmo_fallback(&in, COSMO_BE_DXVK); CHECK(d.verdict == COSMO_INCOMPATIBLE && d.backend == COSMO_BE_NONE, "after DXVK: verdict %d backend %d", d.verdict, d.backend); }
TEST(row12_d3d12_has_no_next) { auto in = base(); in.apis = COSMO_API_D3D12; in.serves[COSMO_BE_D3DMETAL] = COSMO_API_D3D11 | COSMO_API_D3D12;
    auto d = cosmo_fallback(&in, COSMO_BE_D3DMETAL); CHECK(d.verdict == COSMO_INCOMPATIBLE && d.backend == COSMO_BE_NONE, "DXVK can't serve D3D12: verdict %d backend %d", d.verdict, d.backend); }
TEST(row12_d3d12_falls_to_vkd3d_proton) { auto in = base(); in.apis = COSMO_API_D3D12; in.serves[COSMO_BE_D3DMETAL] = COSMO_API_D3D11 | COSMO_API_D3D12;
    in.serves[COSMO_BE_VKD3D_PROTON] = COSMO_API_D3D12;
    auto d = cosmo_fallback(&in, COSMO_BE_D3DMETAL); CHECK(d.verdict == COSMO_USE && d.backend == COSMO_BE_VKD3D_PROTON, "D3DMetal crash → vkd3d-proton: verdict %d backend %d", d.verdict, d.backend);
    d = cosmo_fallback(&in, COSMO_BE_VKD3D_PROTON); CHECK(d.verdict == COSMO_INCOMPATIBLE && d.backend == COSMO_BE_NONE, "after vkd3d-proton: verdict %d backend %d", d.verdict, d.backend);
    in.apis = COSMO_API_D3D11; d = cosmo_fallback(&in, COSMO_BE_DXVK); CHECK(d.verdict == COSMO_INCOMPATIBLE, "vkd3d-proton can't serve D3D11: verdict %d backend %d", d.verdict, d.backend); }
TEST(row12_user_pin_is_asked_about) { auto in = base(); in.game_pin = COSMO_BE_DXMT;
    auto d = cosmo_fallback(&in, COSMO_BE_DXMT);
    CHECK(d.verdict == COSMO_ASK && d.backend == COSMO_BE_DXVK && d.noptions == 2 && d.options[0] == COSMO_BE_DXVK && d.options[1] == COSMO_BE_NONE, "verdict %d backend %d n %d", d.verdict, d.backend, d.noptions); }
TEST(row12_boundary) { CHECK(cosmo_fallback(nullptr, COSMO_BE_DXMT).error == 1, "null input");
    setenv("COSMO_NATIVE_TEST_THROW", "1", 1); auto in = base(); auto d = cosmo_fallback(&in, COSMO_BE_DXMT); unsetenv("COSMO_NATIVE_TEST_THROW");
    CHECK(d.error == 2, "an exception inside must come back as error 2 (got %d)", d.error); }

// Pre-flight rules (item 28): one test per rule, both bitnesses, the .NET header, and the boundary.
static cosmo_preflight_result pf(const char *csv, int is32 = 0, int clr = 0) { return cosmo_preflight(csv, is32, clr); }
TEST(preflight_apis_from_imports) { auto r = pf("kernel32.dll,d3d11.dll,dxgi.dll,ddraw.dll,d3d10_1.dll");
    CHECK(r.apis == (COSMO_API_D3D11 | COSMO_API_DDRAW | COSMO_API_D3D10) && r.needs == 0, "apis %x needs %x", r.apis, r.needs); }
TEST(preflight_vc_runtime_follows_bitness) { CHECK(pf("vcruntime140.dll", 0).needs == COSMO_NEED_VCREDIST64, "64-bit: %x", pf("vcruntime140.dll", 0).needs);
    CHECK(pf("msvcp140_1.dll", 1).needs == COSMO_NEED_VCREDIST86, "32-bit: %x", pf("msvcp140_1.dll", 1).needs);
    CHECK(pf("msvcp120.dll,msvcrt.dll").needs == 0, "older VC runtimes and msvcrt are not ours: %x", pf("msvcp120.dll,msvcrt.dll").needs); }
TEST(preflight_directx_june_2010) { CHECK(pf("d3dx9_43.dll").needs == COSMO_NEED_DIRECTX && pf("xinput1_3.dll").needs == COSMO_NEED_DIRECTX
          && pf("d3dcompiler_43.dll").needs == COSMO_NEED_DIRECTX, "d3dx9/xinput1_3/d3dcompiler_43");
    CHECK(pf("d3dcompiler_47.dll,xinput9_1_0.dll").needs == 0, "d3dcompiler_47 and xinput9_1_0 ship with Windows: %x", pf("d3dcompiler_47.dll,xinput9_1_0.dll").needs); }
TEST(preflight_dotnet_by_header_or_import) { CHECK(pf("", 0, 1).needs == COSMO_NEED_DOTNET, "CLR header alone");
    CHECK(pf("mscoree.dll").needs == COSMO_NEED_DOTNET, "mscoree import alone"); CHECK(pf("kernel32.dll").needs == 0, "neither"); }
TEST(preflight_boundary) { CHECK(cosmo_preflight(nullptr, 0, 0).error == 1, "null input");
    setenv("COSMO_NATIVE_TEST_THROW", "1", 1); auto r = cosmo_preflight("d3d11.dll", 0, 0); unsetenv("COSMO_NATIVE_TEST_THROW");
    CHECK(r.error == 2, "an exception inside must come back as error 2 (got %d)", r.error); }

// Anti-cheat rules (item 29): one test per rule and the precedence between them.
static cosmo_ac_result ac(uint32_t f, int a) { return cosmo_anticheat(f, a); }
TEST(ac_kernel_blocks_whatever_awacy_says) { auto r = ac(COSMO_AC_KERNEL | COSMO_AC_EAC, COSMO_AWACY_SUPPORTED);
    CHECK(r.verdict == COSMO_BLOCK && r.reason == COSMO_ACR_KERNEL, "verdict %d reason %d", r.verdict, r.reason); }
TEST(ac_denied_and_broken_block) { CHECK(ac(COSMO_AC_EAC, COSMO_AWACY_DENIED).reason == COSMO_ACR_DENIED && ac(0, COSMO_AWACY_DENIED).verdict == COSMO_BLOCK, "denied");
    CHECK(ac(COSMO_AC_BATTLEYE, COSMO_AWACY_BROKEN).reason == COSMO_ACR_BROKEN && ac(0, COSMO_AWACY_BROKEN).verdict == COSMO_BLOCK, "broken"); }
TEST(ac_user_mode_or_listed_asks) { CHECK(ac(COSMO_AC_EAC, COSMO_AWACY_UNKNOWN).verdict == COSMO_ASK && ac(COSMO_AC_BATTLEYE, 0).reason == COSMO_ACR_ONLINE, "files only");
    CHECK(ac(0, COSMO_AWACY_SUPPORTED).verdict == COSMO_ASK && ac(0, COSMO_AWACY_RUNNING).verdict == COSMO_ASK && ac(0, COSMO_AWACY_PLANNED).verdict == COSMO_ASK, "listed as working on Proton"); }
TEST(ac_nothing_known_uses) { auto r = ac(0, COSMO_AWACY_UNKNOWN); CHECK(r.verdict == COSMO_USE && r.reason == COSMO_ACR_NONE, "verdict %d", r.verdict); }
TEST(ac_boundary) { setenv("COSMO_NATIVE_TEST_THROW", "1", 1); auto r = ac(COSMO_AC_EAC, 0); unsetenv("COSMO_NATIVE_TEST_THROW");
    CHECK(r.error == 2, "an exception inside must come back as error 2 (got %d)", r.error); }

int main() {
    if (failures) printf("decision tests: %d FAILED of %d\n", failures, tests);
    else printf("decision tests: all %d passed (rows 1-12, precedence, scenario A, pre-flight, anti-cheat, boundaries)\n", tests);
    return failures != 0;
}
