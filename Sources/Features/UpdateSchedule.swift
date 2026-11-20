import SwiftUI

extension Model {
    // Weekly, in the background: installs newer DXMT, DXVK and DXVK 3 releases by itself (each previous version kept as <name>.old,
    // restored if the install fails), but only while no game runs, so no game loses a driver mid-session; otherwise it only reports and
    // tries again next time. Also: the newest D3DMetal already on this Mac becomes the active one, and a newer Game Porting Toolkit
    // download is pointed out (Apple's license: never installed without you).
    func checkDriverUpdates() {
        guard !cliMode, !isTestBuild else { return }   // command-line runs and the test build never start the weekly downloads
        log += preferNewestD3DMetal() + newerGPTKHint()
        let stamp = support + "/.driver-check"
        if let m = (try? FileManager.default.attributesOfItem(atPath: stamp))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 7 * 86400 { return }
        let install = !gameRunning()
        Task.detached { let out = Model.performUpdate(install: install); await MainActor.run { logToFile(out); self.log += out; self.updateStatus() } }
    }
    func gameRunning() -> Bool { bottles.contains { Model.gameRunning(in: $0) } }
    // A game runs in this bottle: a process working inside steamapps/common (Wine keeps a process's working folder on its Windows
    // folder; a game's process may be named just "eldenring.exe", so its name alone can't tell), or one whose command names that folder.
    nonisolated static func gameRunning(in bottle: String) -> Bool {
        let b = realPath("\(bottlesDir)/\(bottle)")
        return !procFind("", under: b + "/drive_c/Program Files (x86)/Steam/steamapps/common").isEmpty || !procFind("steamapps\\common", under: b).isEmpty
    }

    // A newer D3DMetal kept as renderer/d3dmetal@<version> (moved aside by an earlier install or swap) becomes the active one again;
    // the active one is kept as its own d3dmetal@<version>. Never while a game runs: every running game has the framework loaded.
    func preferNewestD3DMetal() -> String {
        let fm = FileManager.default
        guard !gameRunning(), let cur = d3dmetalNow?.version,
              let best = ((try? fm.contentsOfDirectory(atPath: driversDir)) ?? []).filter({ $0.hasPrefix("d3dmetal@") })
                .compactMap({ n in Model.d3dmetalInfo("\(driversDir)/\(n)").map { (n, $0.version) } })
                .max(by: { Model.d3dmetalOlder($0.1, than: $1.1) }),
              Model.d3dmetalOlder(cur, than: best.1) else { return "" }
        guard backUpD3DMetal() != nil, (try? fm.moveItem(atPath: "\(driversDir)/\(best.0)", toPath: "\(driversDir)/d3dmetal")) != nil else {
            return "D3DMetal: could not switch to the newer \(best.1) kept at \(best.0).\n" }
        d3dmetalOK = checkD3DMetalAccepted(); updateStatus(); verifyAll()
        return "D3DMetal: now using \(best.1) (newest on this Mac); \(cur) kept as d3dmetal@\(cur).\n"
            + (d3dmetalOK ? "" : "D3DMetal \(best.1): accept Apple's license in Drivers › D3DMetal… to enable it.\n")
    }
    // A Game Porting Toolkit download newer than the installed D3DMetal: a mounted volume, or a .dmg in Downloads (version from its name).
    func newerGPTKHint() -> String {
        let fm = FileManager.default, cur = d3dmetalNow?.version ?? "0"
        var found: [(String, String)] = []
        for v in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            for lib in ["/Volumes/\(v)/redist/lib", "/Volumes/\(v)/lib"] where fm.fileExists(atPath: lib + "/external/D3DMetal.framework") {
                if let i = Model.d3dmetalInfo(lib) { found.append((i.version, "/Volumes/\(v)")) }
            }
        }
        let dl = NSHomeDirectory() + "/Downloads"
        for f in (try? fm.contentsOfDirectory(atPath: dl)) ?? [] where f.lowercased().hasSuffix(".dmg")
            && (f.localizedCaseInsensitiveContains("porting") || f.localizedCaseInsensitiveContains("windows games")) {
            if let r = f.range(of: #"\d+\.\d+(b\d+)?"#, options: .regularExpression) { found.append((String(f[r]), "\(dl)/\(f)")) }
        }
        guard let n = found.filter({ Model.d3dmetalOlder(cur, than: $0.0) }).max(by: { Model.d3dmetalOlder($0.0, than: $1.0) }) else { return "" }
        return "D3DMetal \(n.0) is available in \(n.1) (installed: \(cur)). Drivers › D3DMetal… installs it.\n"
    }
    // The Update… button: shows what would change and replaces nothing without a yes.
    func updateDrivers() {
        guard !busy else { return }
        busy = true; driverUpdates = "checking upstream…"
        Task.detached {
            let pending = Model.latestDriverTags().filter { !Model.isCurrent($0) }
            await MainActor.run {
                self.busy = false; self.driverUpdates = ""
                guard !pending.isEmpty else { self.log += "Drivers: DXMT and DXVK are current.\n"; return }
                let a = NSAlert(); a.messageText = "Replace these drivers with upstream releases?"
                a.informativeText = pending.map { "\($0.name): \($0.installed) → \($0.tag)" }.joined(separator: "\n")
                    + "\n\nThe installed builds are the tested Sikarugir ones. Each is kept as <name>.old, so you can switch back."
                a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
                guard a.runModal() == .alertFirstButtonReturn else { self.log += "Drivers: nothing replaced.\n"; return }
                self.busy = true; self.driverUpdates = "installing…"
                Task.detached { let out = Model.performUpdate(install: true, newest: true); await MainActor.run { logToFile(out); self.log += out; self.busy = false; self.driverUpdates = ""; self.updateStatus() } }
            }
        }
    }
    // A driver folder that went missing comes back from the pinned template (verified by tree hash), not from a newer upstream release.
    func restoreMissingDrivers() {
        guard let app = Pins.verifiedTemplate() else { log += "A driver folder is missing and the pinned Sikarugir template isn't on disk; run setup again.\n"; return }
        for d in ["dxmt", "dxvk", "dxvk3", "d9vk", "cnc_ddraw"] where !FileManager.default.fileExists(atPath: "\(driversDir)/\(d)/wine") {
            _ = shell("cp -cR \(shq("\(app)/Contents/SharedSupport/renderer/\(d)")) \(shq("\(driversDir)/\(d)"))")
            log += FileManager.default.fileExists(atPath: "\(driversDir)/\(d)/wine") ? "Restored the missing driver \(d) from \(Pins.sikarugirTemplate).\n" : "✗ Could not restore \(d).\n"
        }
        updateStatus()
    }
}
