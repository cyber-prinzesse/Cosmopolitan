// System queries done natively instead of spawning ps / pgrep / ioreg / pmset / sysctl shells (each spawn costs 20–60 ms, and the
// status refresh runs every 5 s). IOKit for HID controllers and power source, libproc + sysctl(KERN_PROCARGS2) for process search.
#include "cosmo_native.h"
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <CoreFoundation/CoreFoundation.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <string>
#include <vector>
#include <cstdlib>
#include <cstring>
#include <new>

namespace {
std::string cfstr(CFTypeRef v) {
    if (!v || CFGetTypeID(v) != CFStringGetTypeID()) return "";
    char buf[256]; return CFStringGetCString((CFStringRef)v, buf, sizeof buf, kCFStringEncodingUTF8) ? buf : "";
}
CFDictionaryRef usage_match(uint32_t page, uint32_t usage) {
    CFNumberRef p = CFNumberCreate(nullptr, kCFNumberSInt32Type, &page), u = CFNumberCreate(nullptr, kCFNumberSInt32Type, &usage);
    const void *keys[] = { CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey) }, *vals[] = { p, u };
    CFDictionaryRef d = CFDictionaryCreate(nullptr, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(p); CFRelease(u); return d;
}
}

// Connected game controllers (gamepads, joysticks, multi-axis), comma-separated product names. Returns the count.
static int controllers(char *out, size_t cap) {
    if (cap) out[0] = 0;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!m) return 0;
    CFDictionaryRef g = usage_match(kHIDPage_GenericDesktop, kHIDUsage_GD_GamePad), j = usage_match(kHIDPage_GenericDesktop, kHIDUsage_GD_Joystick), x = usage_match(kHIDPage_GenericDesktop, kHIDUsage_GD_MultiAxisController);
    const void *arr[] = { g, j, x }; CFArrayRef matches = CFArrayCreate(nullptr, arr, 3, &kCFTypeArrayCallBacks);
    IOHIDManagerSetDeviceMatchingMultiple(m, matches);
    CFSetRef set = IOHIDManagerCopyDevices(m);
    int n = 0; std::string names;
    if (set) {
        CFIndex c = CFSetGetCount(set); std::vector<const void *> devs(c); CFSetGetValues(set, devs.data());
        for (CFIndex i = 0; i < c; i++) {
            IOHIDDeviceRef d = (IOHIDDeviceRef)devs[i];
            std::string name = cfstr(IOHIDDeviceGetProperty(d, CFSTR(kIOHIDProductKey)));
            if (name.empty()) continue;
            if (names.find(name) == std::string::npos) { if (!names.empty()) names += ", "; names += name; n++; }
        }
        CFRelease(set);
    }
    CFRelease(matches); CFRelease(g); CFRelease(j); CFRelease(x); CFRelease(m);
    if (cap) { strncpy(out, names.c_str(), cap - 1); out[cap - 1] = 0; }
    return n;
}

// 1 when running on battery, 0 on AC/UPS, -1 unknown.
static int on_battery() {
    CFTypeRef info = IOPSCopyPowerSourcesInfo(); if (!info) return -1;
    CFStringRef t = IOPSGetProvidingPowerSourceType(info);
    int r = t ? (CFStringCompare(t, CFSTR(kIOPMBatteryPowerKey), 0) == kCFCompareEqualTo ? 1 : 0) : -1;
    CFRelease(info); return r;
}

// PIDs of processes whose executable path or argv[0] contains `needle` (case-sensitive) and, when `cwd_under` is given, whose working
// folder is that folder or inside it. Wine keeps each process's Unix working folder on its Windows current directory, so that tells
// bottles apart (Wine overwrites the argument and environment block with the Windows command line: WINEPREFIX can't be read back).
// Excludes the caller. Returns count.
static int proc_find(const char *needle, const char *cwd_under, int32_t *pids, int cap) {
    int n = proc_listallpids(nullptr, 0); if (n <= 0) return 0;
    std::vector<pid_t> all(n * 2); n = proc_listallpids(all.data(), (int)(all.size() * sizeof(pid_t))); if (n <= 0) return 0;
    pid_t me = getpid(); int found = 0;
    size_t argmax = 0; { int mib[2] = { CTL_KERN, KERN_ARGMAX }; int am = 0; size_t sz = sizeof am; if (sysctl(mib, 2, &am, &sz, nullptr, 0) == 0) argmax = (size_t)am; }
    std::vector<char> buf((argmax ? argmax : 65536) + 1);   // +1: room for a terminator, whatever the kernel returns
    for (int i = 0; i < n && found < cap; i++) {
        pid_t pid = all[i]; if (pid <= 0 || pid == me) continue;
        int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid }; size_t sz = buf.size() - 1;
        if (sysctl(mib, 3, buf.data(), &sz, nullptr, 0) != 0 || sz < sizeof(int)) continue;
        buf[sz] = 0;
        // layout: argc, exec path, NULs, argv[0], argv[1]… — only the exec path and argv[0] are matched: Wine rewrites argv[0] to the
        // Windows command ("C:\…\steam.exe"), and helper processes carry the parent's path in *later* arguments, which must not count.
        const char *p = buf.data() + sizeof(int), *end = buf.data() + sz;
        const char *exe = p; p += strnlen(p, size_t(end - p)) + 1; while (p < end && *p == 0) p++;
        bool hit = strstr(exe, needle) != nullptr || (p < end && strstr(p, needle) != nullptr);
        if (hit && cwd_under && *cwd_under) {
            struct proc_vnodepathinfo vpi; const size_t len = strlen(cwd_under);
            hit = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi) == (int)sizeof vpi && strncmp(vpi.pvi_cdir.vip_path, cwd_under, len) == 0
                  && (vpi.pvi_cdir.vip_path[len] == '/' || vpi.pvi_cdir.vip_path[len] == 0);
        }
        if (hit) pids[found++] = pid;
    }
    return found;
}

// C boundary: noexcept, nothing escapes into Swift. COSMO_TEST_HOOKS builds can force a throw to prove it.
static void test_throw() {
#ifdef COSMO_TEST_HOOKS
    if (getenv("COSMO_NATIVE_TEST_THROW")) throw std::bad_alloc();
#endif
}
extern "C" int cosmo_controllers(char *out, size_t cap) noexcept {
    try { test_throw(); return controllers(out, cap); } catch (...) { if (out && cap) out[0] = 0; return 0; }
}
extern "C" int cosmo_on_battery(void) noexcept {
    try { test_throw(); return on_battery(); } catch (...) { return -1; }
}
extern "C" int cosmo_proc_find_in(const char *needle, const char *cwd_under, int32_t *pids, int cap) noexcept {
    if (!needle || !pids || cap <= 0) return 0;
    try { test_throw(); return proc_find(needle, cwd_under, pids, cap); } catch (...) { return 0; }
}
extern "C" int cosmo_proc_find(const char *needle, int32_t *pids, int cap) noexcept { return cosmo_proc_find_in(needle, nullptr, pids, cap); }

// Rosetta's exception-server thread: when Wine's segv_handler re-enters forever on a Metal/D3DMetal worker (no TEB), this thread
// burns a core continuously. Native (arm64) processes have no such thread → -1, so the Swift watchdog stays idle.
// PROC_PIDLISTTHREADS with a NULL buffer returns 0 / ENOMEM on recent macOS — always use a fixed buffer (thread id 0 is valid).
static int64_t rosetta_exc_cpu_ns(int32_t pid) {
    if (pid <= 0) return -1;
    uint64_t tids[512];
    int nb = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, tids, (int)sizeof tids);
    if (nb <= 0) return -1;
    int n = nb / (int)sizeof(uint64_t);
    for (int i = 0; i < n; i++) {
        struct proc_threadinfo ti; memset(&ti, 0, sizeof ti);
        if (proc_pidinfo(pid, PROC_PIDTHREADINFO, tids[i], &ti, (int)sizeof ti) != (int)sizeof ti) continue;
        if (strncmp(ti.pth_name, "com.apple.rosetta.exceptionserver", sizeof ti.pth_name) != 0) continue;
        return (int64_t)ti.pth_user_time + (int64_t)ti.pth_system_time;   // nanoseconds
    }
    return -1;
}
extern "C" int64_t cosmo_rosetta_exc_cpu_ns(int32_t pid) noexcept {
    try { test_throw(); return rosetta_exc_cpu_ns(pid); } catch (...) { return -1; }
}
