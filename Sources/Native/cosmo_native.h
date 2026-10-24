// C interface of Cosmopolitan's native (C++) module. Imported into Swift as the bridging header.
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
#define COSMO_NOEXCEPT noexcept   // every boundary function: C++ definitions must be noexcept (Swift can't catch C++ exceptions)
extern "C" {
#else
#define COSMO_NOEXCEPT
#endif

typedef struct {
    uint64_t instructions;   // instructions walked in executable sections
    uint64_t vex;            // VEX-encoded (AVX / AVX2 / FMA / BMI)
    uint64_t evex;           // EVEX-encoded (AVX-512) — Rosetta cannot execute these
    uint64_t code_bytes;     // bytes of executable sections scanned
    int32_t  error;          // 0 ok, 1 cannot open, 2 not a PE or truncated, 3 not x86-64, 4 internal error
} cosmo_avx_result;

// Scans a Windows PE32+ executable or DLL. Takes ~0.1 s for 25 MB; never executes anything.
cosmo_avx_result cosmo_avx_scan(const char *path) COSMO_NOEXCEPT;

typedef struct {
    int32_t  kind;             // 0 not an executable, 1 DOS, 2 Win16 (NE), 3 PE
    uint16_t machine;          // 0x8664 x86-64, 0x14c i386, 0xaa64 arm64
    uint16_t subsystem_major;  // 4 = Win95/NT4 era, 5 = 2000/XP, 6+ = Vista and later
    uint8_t  linker_major;     // 6 = VC6, 7–9 = VC2002–2008, 10+ = 2010+, 2 = GNU ld
    uint32_t delay_imports;    // number of delay-load import entries (also included in the imports list)
    int32_t  error;            // 0 ok, 1 cannot open, 2 truncated or malformed header, 3 internal error
    uint8_t  clr;              // 1 = has a .NET (CLR) header: a managed program, whatever it imports
} cosmo_pe_info;
// Reads header facts and the lower-cased import DLL lists: `imports` = normal (required) imports; `delay` = delay-load-only imports
// (loaded at runtime, optional — not in `imports`). Both comma-separated.
cosmo_pe_info cosmo_pe_read(const char *path, char *imports, size_t cap, char *delay, size_t delaycap) COSMO_NOEXCEPT;

// Connected game controllers via IOKit HID (gamepads, joysticks, multi-axis). Writes comma-separated product names; returns count.
int cosmo_controllers(char *out, size_t cap) COSMO_NOEXCEPT;
// 1 on battery, 0 on mains, -1 unknown (IOKit power sources).
int cosmo_on_battery(void) COSMO_NOEXCEPT;
// PIDs whose executable path or argv[0] contains `needle` (excluding the caller); later arguments are ignored on purpose. Returns the number written.
int cosmo_proc_find(const char *needle, int32_t *pids, int cap) COSMO_NOEXCEPT;
int cosmo_proc_find_in(const char *needle, const char *cwd_under, int32_t *pids, int cap) COSMO_NOEXCEPT;   // …working inside cwd_under

// ---- Compatibility decision: a pure function over plain values (docs/design/compat-gate.md §3.6). Thread-safe, no I/O. ----
enum { COSMO_API_DDRAW = 1u << 0, COSMO_API_D3D8 = 1u << 1, COSMO_API_D3D9 = 1u << 2, COSMO_API_D3D10 = 1u << 3, COSMO_API_D3D11 = 1u << 4, COSMO_API_D3D12 = 1u << 5 };
typedef enum { COSMO_BE_NONE = 0, COSMO_BE_D3DMETAL, COSMO_BE_DXMT, COSMO_BE_DXVK, COSMO_BE_VKD3D_PROTON, COSMO_BE_CNC_DDRAW, COSMO_BE_WINED3D, COSMO_BE_COUNT } cosmo_backend;
typedef enum { COSMO_DB_UNKNOWN = 0, COSMO_DB_KNOWN_GOOD, COSMO_DB_EXPERIMENTAL, COSMO_DB_BROKEN } cosmo_db_status;
typedef enum { COSMO_USE = 0, COSMO_ASK, COSMO_BLOCK, COSMO_INCOMPATIBLE } cosmo_verdict;
enum { COSMO_WARN_RAM = 1u << 0, COSMO_WARN_RT_NO_HARDWARE = 1u << 1, COSMO_WARN_AVX512 = 1u << 2 };
typedef struct {
    uint32_t apis;                          // COSMO_API_* the game uses
    uint8_t  is32, kernel_anticheat, needs_avx2, avx512_paths, rt_on_in_game;
    uint8_t  rosetta_ok, rosetta_avx2_ok;   // from probes (Rosetta runs x86 code; the AVX2 probe program ran)
    uint8_t  gpu_family;                    // MTLGPUFamilyApple<n>: 7 = M1 … 9 = M3/M4 (hardware ray tracing) … 10 = M5
    uint32_t ram_gb, game_min_ram_gb;       // game_min_ram_gb from the compatibility DB, 0 = unknown
    uint32_t serves[COSMO_BE_COUNT];        // per backend: API bits it can serve here (installed, right bitness, capabilities met); 0 = unavailable
    uint32_t implements[COSMO_BE_COUNT];    // per backend: API bits it implements at all, installed or not (to rank alternatives)
    uint8_t  db_status[COSMO_BE_COUNT];     // cosmo_db_status for this game
    uint8_t  failed_here[COSMO_BE_COUNT];   // outcome log: this backend's installed version crashed this game early on this Mac
    int32_t  game_pin, global_pin, db_known_good;   // cosmo_backend, COSMO_BE_NONE = none
} cosmo_decision_input;
typedef struct {
    int32_t  verdict, row, backend;         // cosmo_verdict; decision-table row 1–11; chosen or proposed cosmo_backend
    int32_t  options[4];                    // ranked choices for ASK and INCOMPATIBLE; COSMO_BE_NONE means "cancel"
    uint8_t  option_available[4];           // 0 = shown greyed out (not installed, or can't run here)
    int32_t  noptions;
    uint32_t warnings;                      // COSMO_WARN_*
    int32_t  error;                         // 0 ok, 1 no input, 2 internal error
} cosmo_decision;
cosmo_decision cosmo_decide(const cosmo_decision_input *in) COSMO_NOEXCEPT;
// Row 12, driver fallback: `crashed` failed this game within 30 s. USE the next backend of DXMT → D3DMetal → DXVK that serves the main
// API and hasn't failed here; ASK (with that proposal) when the user pinned the crashed one; INCOMPATIBLE with backend NONE when none is left.
cosmo_decision cosmo_fallback(const cosmo_decision_input *in, int32_t crashed) COSMO_NOEXCEPT;
// ---- Pre-flight (item 28): what a program needs before it starts, from import names (its own and those of the DLLs beside it), its
// bitness and its .NET header. Pure: names in, flags out. ----
enum { COSMO_NEED_DOTNET = 1u << 0, COSMO_NEED_VCREDIST86 = 1u << 1, COSMO_NEED_VCREDIST64 = 1u << 2, COSMO_NEED_DIRECTX = 1u << 3 };
typedef struct { uint32_t apis, needs; int32_t error; } cosmo_preflight_result;   // apis: COSMO_API_*; error 0 ok, 1 no input, 2 internal
cosmo_preflight_result cosmo_preflight(const char *imports_csv, int32_t is32, int32_t clr) COSMO_NOEXCEPT;
// ---- Anti-cheat (item 29): what was found (files in the game folder, community lists) and AreWeAntiCheatYet's status → a verdict. ----
enum { COSMO_AC_EAC = 1u << 0, COSMO_AC_BATTLEYE = 1u << 1, COSMO_AC_KERNEL = 1u << 2 };
typedef enum { COSMO_AWACY_UNKNOWN = 0, COSMO_AWACY_SUPPORTED, COSMO_AWACY_RUNNING, COSMO_AWACY_PLANNED, COSMO_AWACY_BROKEN, COSMO_AWACY_DENIED } cosmo_awacy;
typedef enum { COSMO_ACR_NONE = 0, COSMO_ACR_KERNEL, COSMO_ACR_DENIED, COSMO_ACR_BROKEN, COSMO_ACR_ONLINE } cosmo_ac_reason;
typedef struct { int32_t verdict, reason, error; } cosmo_ac_result;   // verdict: COSMO_USE (none known), COSMO_ASK (online likely broken), COSMO_BLOCK
cosmo_ac_result cosmo_anticheat(uint32_t found, int32_t awacy) COSMO_NOEXCEPT;

#ifdef __cplusplus
}
#endif
