import SwiftUI

extension Model {
    // §9.4 Offline readiness: what will and won't start without internet.
    func offlineCheck() {
        var out = "── Offline check (\(selected)) ──\n"
        let steam = programs.contains { $0.lowercased().hasSuffix("/steam/steam.exe") }
        if steam { out += "• Steam itself: start it once while online, then use Steam › Go Offline before leaving; Steam games start offline only after that.\n" }
        for p in programs where !p.lowercased().hasSuffix("/steam/steam.exe") {
            let r = readiness[p]
            if r?.anticheat != nil { out += "✗ \(appName(p)): online-only (anti-cheat) — will not start offline.\n" }
            else if steamGames[p] != nil { out += "• \(appName(p)): Steam DRM — works offline once Steam is in Offline Mode; cloud saves won't sync.\n" }
            else { out += "✓ \(appName(p)): standalone program, no online check known.\n" }
        }
        logToFile(out); log += out + "──\n"
    }
}
