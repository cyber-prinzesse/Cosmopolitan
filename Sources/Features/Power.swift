import SwiftUI
import IOKit

extension Model {
    // §6.3 Power and thermal hints, logged at launch when they would change the experience.
    func powerHints() -> String {
        var out = ""
        if ProcessInfo.processInfo.isLowPowerModeEnabled { out += "⚠ Low Power Mode is on: the battery profile is used (60 fps cap, lighter rendering); System Settings › Battery turns it off.\n" }
        if let l = Int(sh("pmset -g therm 2>/dev/null | awk '/CPU_Speed_Limit/{print $3}'")), l < 100 { out += "⚠ Thermal pressure: CPU limited to \(l)% right now; let the Mac cool or lower settings.\n" }
        if powerReason() == "fanless Mac" { out += "MacBook Air (no fan): games start with the cooler profile (60 fps cap, lighter rendering), so they stay steady once the Mac warms up instead of slowing down mid-game; FULL_SPEED=1 in a game's Options… turns it off for that game.\n" }
        if onBattery() { out += "On battery: DXMT games are capped at 60 fps with lighter rendering; Direct3D 12 games " + (d3dmetalFrameCap() ? "are capped at 60 fps by D3DMetal.\n" : "are not capped (this D3DMetal has no frame limiter).\n") }
        return out
    }
    // Item 25: the battery part of the Automatic summary, true to the installed D3DMetal (3.0 has no frame limiter; the 4.0 beta has one).
    func batterySummary() -> String {
        guard let d = d3dmetalNow else { return "60 fps cap and lighter rendering while on battery" }
        return d3dmetalFrameCap() ? "60 fps cap and lighter rendering while on battery (D3DMetal \(d.pretty) games capped too)"
                                  : "60 fps cap and lighter rendering while on battery for DXMT games; D3DMetal \(d.pretty) games: cap not available"
    }
}

// The battery profile applies on battery, in Low Power Mode, or when macOS reports serious thermal pressure (item 32: not only unplugged),
// and always on a fanless Mac. Test build only: COSMO_TEST_POWER=battery|lowpower|thermal|fanless|plugged fixes the state
// (COSMO_TEST_ON_BATTERY=1 = battery).
func batteryCapWanted() -> Bool { powerReason() != nil }
func powerReason() -> String? {
    let p = ProcessInfo.processInfo, t = isTestBuild ? (p.environment["COSMO_TEST_POWER"] ?? (p.environment["COSMO_TEST_ON_BATTERY"] == "1" ? "battery" : nil)) : nil
    if let t { return ["battery": "on battery", "lowpower": "Low Power Mode", "thermal": "serious thermal pressure", "fanless": "fanless Mac"][t] }
    if onBattery() { return "on battery" }
    if p.isLowPowerModeEnabled { return "Low Power Mode" }
    if p.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return "serious thermal pressure" }
    return isFanless ? "fanless Mac" : nil
}
// A MacBook Air has no fan: a game runs at full speed for 10–15 minutes, then the Mac throttles hard while the game still pushes for every
// frame, and it stutters. Waiting for "serious thermal pressure" switches the profile on only at the next launch, too late; on these Macs
// it applies from the start. Apple silicon names the model in the device tree (IODeviceTree:/product, "MacBook Air (M2, 2022)").
let isFanless: Bool = {
    let e = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product"); defer { if e != 0 { IOObjectRelease(e) } }
    guard e != 0, let d = IORegistryEntryCreateCFProperty(e, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return false }
    return String(decoding: d, as: UTF8.self).hasPrefix("MacBook Air")
}()
// Whether the installed D3DMetal has its documented frame limiter (D3DM_MAX_FPS, in the 4.0 beta Read Me; absent from 3.0). Cached per framework file.
private let frameCapLock = NSLock()
nonisolated(unsafe) private var frameCapCache = (key: "", has: false)
func d3dmetalFrameCap() -> Bool {
    let bin = driversDir + "/d3dmetal/external/D3DMetal.framework/D3DMetal"
    let a = try? FileManager.default.attributesOfItem(atPath: bin)
    let key = "\((a?[.size] as? NSNumber)?.intValue ?? 0)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    frameCapLock.lock(); defer { frameCapLock.unlock() }
    if frameCapCache.key != key { frameCapCache = (key, a != nil && (Model.d3dmetalInfo(driversDir + "/d3dmetal")?.features.contains("D3DM_MAX_FPS") ?? false)) }
    return frameCapCache.has
}
