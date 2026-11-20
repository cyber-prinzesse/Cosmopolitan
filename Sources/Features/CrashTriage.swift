import SwiftUI

extension Model {
    // Known failure signatures in the log and what they mean. Used by Troubleshoot and by crash triage.
    static let logSigns = ["version mismatch": "two Wine builds touched this bottle → Repair, then relaunch",
                           "dx11 device creation fail": "no D3D11 driver reached the game → check Drivers (dxmt on)",
                           "DirectX 12 is not supported": "game needs d3dmetal; start it from Cosmopolitan so Steam is restarted with it",
                           "Failed to dlopen D3DMetal": "D3DMetal framework path wrong or files missing → Update… re-syncs d3dmetal",
                           "Failed loading SDL3": "SDL3 missing beside the engine",
                           "detached already": "Wine 11.x Mac driver bug; this engine must stay 10.0",
                           "Library not loaded": "a dylib the engine needs is missing (see the line above it in the log)",
                           "c000001d": "Illegal instruction → the program needs AVX; Rosetta AVX is switched on for it",
                           "Illegal instruction": "Illegal instruction → the program needs AVX; Rosetta AVX is switched on for it"]
    // Crash triage: a program that dies within a minute gets the recent log matched against the signatures and the known fix applied.
    func triage(_ exe: String, _ code: Int32) {
        let name = (exe as NSString).lastPathComponent, fm = FileManager.default
        let tail = String(((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").suffix(20000))
        let hits = Model.logSigns.filter { tail.contains($0.key) }
        var out = "⚠ \(name) exited almost immediately (code \(code)).\n"
        problem = (exe, "\(appName(exe)) closed right after it started.")   // the Library shows it with a Fix button
        for (s, hint) in hits { out += "  • \"\(s)\": \(hint)\n" }
        if hits["version mismatch"] != nil { out += "  → running Repair\n"; log += out; repair(); return }
        if hits["c000001d"] != nil || hits["Illegal instruction"] != nil {   // §4.3: enable AVX for this program after an illegal-instruction crash
            var t = (try? String(contentsOfFile: optionsPath(exe), encoding: .utf8)) ?? Model.optionsTemplate
            if !t.contains("ROSETTA_ADVERTISE_AVX") { t += "\nROSETTA_ADVERTISE_AVX=1\n"; saveOptions(exe, t) }
            out += "  → ROSETTA_ADVERTISE_AVX=1 saved in this program's Options. Try again.\n"; log += out; return
        }
        // A driver updated in the last 7 days is the prime suspect: offer to roll it back (never without asking: it replaces what you
        // installed), keeping the new one aside.
        for d in (try? fm.contentsOfDirectory(atPath: driversDir)) ?? [] where d.hasSuffix(".old") {
            let name = String(d.dropLast(4)), cur = "\(driversDir)/\(name)"
            if let m = (try? fm.attributesOfItem(atPath: cur))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 7 * 86400,
               ask("Go back to the previous \(name)?", "\(appName(exe)) closed right after starting, and \(name) was updated in the last 7 days. The new version is kept aside.", yes: "Go back") {
                _ = sh("rm -rf \(shq("\(cur).bad")); mv \(shq("\(cur)")) \(shq("\(cur).bad")) && mv \(shq("\(driversDir)/\(d)")) \(shq("\(cur)"))")
                out += "  → driver \(name) was updated recently; rolled back to the previous version (new one kept as \(name).bad). Try again.\n"
                log += out; updateStatus(); return
            }
        }
        log += out
        if hits.isEmpty { log += "  → no known signature; running Troubleshoot\n"; troubleshoot() }
        explainCrash(name, tail)
    }
}
