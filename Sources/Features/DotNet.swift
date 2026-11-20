import Foundation

// .NET in a bottle: Wine Mono from WineHQ (pinned), and a probe program that must actually run in that bottle before any .NET program
// there can get a green light. The markers hold the probe's line (or its output when it failed).
extension Model {
    nonisolated static func dotnetMarker(_ prefix: String) -> String { prefix + "/.dotnet-verified" }
    nonisolated static func dotnetFailMarker(_ prefix: String) -> String { prefix + "/.dotnet-failed" }

    // Runs Resources/netprobe.exe in the bottle and records the result. Blocking: call off the main actor.
    @discardableResult nonisolated static func probeDotNet(_ prefix: String) -> Bool {
        let fm = FileManager.default, tmp = prefix + "/drive_c/windows/temp"
        guard let probe = Bundle.main.path(forResource: "netprobe", ofType: "exe") else { return false }
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: tmp + "/netprobe.exe"); try? fm.copyItem(atPath: probe, toPath: tmp + "/netprobe.exe")
        let out = shell("cd \(shq("\(tmp)")) && \(plainWine(prefix)) 'C:\\windows\\temp\\netprobe.exe' 2>&1")
        try? fm.removeItem(atPath: tmp + "/netprobe.exe")
        try? fm.removeItem(atPath: dotnetMarker(prefix)); try? fm.removeItem(atPath: dotnetFailMarker(prefix))
        if let line = out.components(separatedBy: "\n").first(where: { $0.hasPrefix("netprobe ok") }) {
            try? "\(line)\n\(ISO8601DateFormatter().string(from: Date()))\n".write(toFile: dotnetMarker(prefix), atomically: true, encoding: .utf8)
            return true
        }
        try? String(out.suffix(600)).write(toFile: dotnetFailMarker(prefix), atomically: true, encoding: .utf8)
        return false
    }

    // Installs the pinned WineHQ Wine Mono into the bottle, then probes. Blocking: call off the main actor.
    @discardableResult nonisolated static func installWineMono(_ prefix: String, log: @escaping (String) -> Void) -> Bool {
        guard let msi = fetchPinned(Pins.wineMono, log: log) else { return false }
        let fm = FileManager.default, tmp = prefix + "/drive_c/windows/temp", dst = tmp + "/" + Pins.wineMono.file
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dst); try? fm.copyItem(atPath: msi, toPath: dst)   // restricted bottles have no Z:, so the MSI goes onto C:
        log("Installing Wine Mono \(Pins.wineMono.version) into the bottle…\n")
        _ = shell("cd \(shq("\(tmp)")) && \(plainWine(prefix)) msiexec /i \(shq("C:\\windows\\temp\\\(Pins.wineMono.file)")) /qn >/dev/null 2>&1")
        try? fm.removeItem(atPath: dst)
        let ok = probeDotNet(prefix)
        log(ok ? "✓ .NET works in this bottle (probe program ran).\n" : "✗ Wine Mono installed, but the .NET probe did not run; .NET programs here stay marked not ready.\n")
        return ok
    }

    // Probe first (a bottle may already have a working runtime); install Wine Mono only when the probe fails.
    @discardableResult nonisolated static func ensureDotNet(_ prefix: String, log: @escaping (String) -> Void) -> Bool {
        probeDotNet(prefix) || installWineMono(prefix, log: log)
    }
}
