import Foundation

// Switching the Wine engine (Settings › Engine). Wine upgrades a bottle the first time a new engine opens it, and a Wine 11 upgrade
// of a Wine 10 bottle can't be undone. So before the new engine is used, snapshot every bottle (APFS clones, cheap and quick); a
// switch is then reversible from Advanced › Manage bottle › Snapshots. Wine 10 stays installed and selectable as the safe fallback.
extension Model {
    func engineSwitched(to newEngine: String) {
        let wine11 = engineIsWine11(newEngine)
        let targets = bottles.filter { FileManager.default.fileExists(atPath: "\(bottlesDir)/\($0)/drive_c") }
        log += "Engine set to \(newEngine)\(wine11 ? " — a Wine 11 beta" : ""). Taking a snapshot of \(targets.count) bottle\(targets.count == 1 ? "" : "s") first…\n"
        Task.detached(priority: .userInitiated) {
            var ok = 0, notes: [String] = []
            for b in targets {
                let r = Model.snapshot(b, "before switching to engine \(newEngine)")
                if r.path != nil { ok += 1 } else { notes.append(r.note) }
            }
            await MainActor.run {
                self.log += "Snapshotted \(ok) of \(targets.count) bottle\(targets.count == 1 ? "" : "s"). Each is upgraded for \(newEngine) the first time it opens"
                    + (wine11 ? ", and a Wine 11 upgrade can't be undone — roll back from Advanced › Manage bottle › Snapshots, or switch back to \(wine10Engine) (Wine 10) and restore.\n" : ".\n")
                for n in notes.prefix(3) { self.log += "  \(n)\n" }
                self.requestSteamRestart("the new engine reaches Steam games when Steam next starts")
            }
        }
    }
}
