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
}
