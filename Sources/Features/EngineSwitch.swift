import Foundation

// Switching the Wine engine (Settings › Engine). Wine upgrades a bottle the first time a new engine opens it, and a Wine 11 upgrade
// of a Wine 10 bottle can't be undone. So before the new engine is used, snapshot every bottle (APFS clones, cheap and quick); a
// switch is then reversible from Advanced › Manage bottle › Snapshots. Wine 10 stays installed and selectable as the safe fallback.
extension Model {
    // Item 3: Battle.net's 32-bit Chromium GPU process exits on Wine 11 (r29: endless spinner) while Wine 10 draws it. The engine is
    // app-wide, so a switch from Wine 10 to Wine 11 asks first when any bottle has Battle.net. False = keep the current engine.
    func battleNetBottles() -> [String] {
        bottles.filter { FileManager.default.fileExists(atPath: "\(bottlesDir)/\($0)/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe") }
    }
    func confirmEngineSwitch(from old: String, to new: String) -> Bool {
        guard engineIsWine11(new), !engineIsWine11(old) else { return true }
        let bn = battleNetBottles()
        guard !bn.isEmpty else { return true }
        return ask("Battle.net doesn't start on Wine 11 yet", "On the Wine 11 beta it stays on an endless spinner; on Wine 10 it works. The engine applies to every bottle, including \(bn.joined(separator: ", ")). Cancel keeps \(old).", yes: "Switch anyway")
    }

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
                    + (wine11 ? ", and a Wine 11 upgrade can't be undone — roll back from Advanced › Manage bottle › Snapshots, or switch back to \(defaultEngine) (Wine 10) and restore.\n" : ".\n")
                for n in notes.prefix(3) { self.log += "  \(n)\n" }
                self.requestSteamRestart("the new engine reaches Steam games when Steam next starts")
            }
        }
    }
}
