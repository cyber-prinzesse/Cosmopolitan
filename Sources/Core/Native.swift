import Foundation
#if canImport(CosmoNative)
import CosmoNative   // swift build: the C++ module is a package target (scripts/build.sh uses the bridging header)
#endif

// Thin Swift faces for the C++ module (Sources/Native). Everything here used to be a shell spawn (ioreg, pmset, ps, pgrep) or a
// byte-walk in Swift; now it is a direct call, which matters because the status refresh runs every 5 seconds.
func nativeControllers() -> [String] {
    var buf = [CChar](repeating: 0, count: 2048)
    let n = cosmo_controllers(&buf, buf.count)
    return n > 0 ? String(cString: buf).components(separatedBy: ", ").filter { !$0.isEmpty } : []
}
func onBattery() -> Bool { cosmo_on_battery() == 1 }
// Processes whose executable path or argv[0] contains `needle` (for Wine processes argv[0] is the Windows command line's exe); never the
// caller. `under`: only those whose working folder is inside that folder (a bottle: Wine keeps it on the program's Windows folder).
func procFind(_ needle: String, under dir: String? = nil) -> [Int32] {
    var pids = [Int32](repeating: 0, count: 256)
    let n = cosmo_proc_find_in(needle, dir, &pids, Int32(pids.count))
    return Array(pids.prefix(Int(n)))
}
func isRunning(_ needle: String) -> Bool { !procFind(needle).isEmpty }
// Item 28: what a program needs, decided in C++ from its imports (and those of the DLLs beside it), bitness and .NET header.
func preflight(_ imports: [String], is32: Bool, clr: Bool) -> cosmo_preflight_result { cosmo_preflight(imports.joined(separator: ","), is32 ? 1 : 0, clr ? 1 : 0) }
// PE facts + imports, lower-cased. `imports` = normal + delay-load (so graphics-API detection still sees a delay-loaded d3d12);
// `delay` = the delay-load-only ones (optional — the program loads them at runtime from its own folders and copes if absent).
func peRead(_ path: String) -> (info: cosmo_pe_info, imports: [String], delay: [String]) {
    var buf = [CChar](repeating: 0, count: 16384), dbuf = [CChar](repeating: 0, count: 4096)
    let info = cosmo_pe_read(path, &buf, buf.count, &dbuf, dbuf.count)
    let norm = String(cString: buf), del = String(cString: dbuf)
    let n = norm.isEmpty ? [] : norm.components(separatedBy: ","), d = del.isEmpty ? [] : del.components(separatedBy: ",")
    return (info, n + d, d)
}
