import SwiftUI

// macOS's free-memory level (0–100 %) and the swap in use (MB), read with sysctl directly: this runs every 30 s, and each shell spawn
// costs 20–60 ms on the main thread.
func memoryState() -> (level: Int, swapMB: Double) {
    var level: Int32 = 100, size = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) != 0 { level = 100 }
    var swap = xsw_usage(), ssize = MemoryLayout<xsw_usage>.size
    let used = sysctlbyname("vm.swapusage", &swap, &ssize, nil, 0) == 0 ? Double(swap.xsu_used) / 1_048_576 : 0
    return (Int(level), used)
}

extension Model {
    // §8.8 Memory-pressure advisor: while a game runs, warn (at most every 10 min) when macOS is low on memory or swapping hard.
    func memoryAdvisor() {
        guard Date().timeIntervalSince(lastMemWarn) > 600 else { return }
        let (level, swap) = memoryState()
        guard level < 20 || swap > 4096 else { return }   // memory first (two sysctls); the process search only under pressure
        guard !procFind("steamapps\\common").isEmpty || !procFind("Program Files").isEmpty else { return }   // a Windows program is running
        lastMemWarn = Date()
        log += "⚠ Memory pressure while a game runs (free level \(level)%, swap \(Int(swap / 1024)) GB): close other apps or lower texture quality; stutter and long loads come from swapping.\n"
    }
    // Before Play on a Mac short of memory (free level under 25 %): the apps holding the most, with the offer to quit them. A game that
    // starts into swap stutters from its first minute, and on 8 GB Macs Steam's window process dies first (the window loop, SteamLoop.swift).
    // Only apps with a Dock icon over 300 MB; never Cosmopolitan, Finder or a Wine program (Steam, the game). Quitting asks each app the
    // normal way, so unsaved work still gets its Save prompt. Test build: COSMO_TEST_MEMLEVEL fixes the level, and nothing is ever quit.
    func freeMemoryBeforePlay() {
        let level = (isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_MEMLEVEL"].flatMap(Int.init) : nil) ?? memoryState().level
        guard level < 25 else { return }
        let big = NSWorkspace.shared.runningApplications.filter { a in
            a.activationPolicy == .regular && a.processIdentifier != getpid() && a.bundleIdentifier != "com.apple.finder"
                && !(a.executableURL?.path ?? "").contains("/wswine.bundle/") && !(a.executableURL?.path ?? "").hasPrefix(support)
        }.map { ($0, footprintMB($0.processIdentifier)) }.filter { $0.1 >= 300 }.sorted { $0.1 > $1.1 }.prefix(4)
        let list = big.map { "\($0.0.localizedName ?? "an app") (\(String(format: "%.1f", $0.1 / 1024)) GB)" }.joined(separator: ", ")
        log += "⚠ Free memory is low (\(level)%) before playing" + (big.isEmpty ? ": close what you don't need, or the game starts into swap and stutters.\n" : "; using the most: \(list).\n")
        guard !big.isEmpty, ask("Quit apps to free memory?", "The Mac is short of memory (\(level)% free), so the game would start into swap and stutter. Using the most: \(list). Each app is asked to quit the normal way, so unsaved work still gets its Save prompt.", yes: "Quit them") else { return }
        for (a, _) in big { if isTestBuild { log += "would quit \(a.localizedName ?? "an app")\n" } else { a.terminate() } }
    }
}

// An app's memory as Activity Monitor's Memory column shows it (physical footprint), in MB; 0 when it can't be read.
func footprintMB(_ pid: pid_t) -> Double {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return r == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
}
