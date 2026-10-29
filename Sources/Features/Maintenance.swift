import Foundation

// Housekeeping, automatic once a day and on the "Clean up" button. Removes what is never needed again (temp files, crash dumps,
// rotated logs, store installers, applied update staging, old download caches) and keeps exactly one previous version of
// everything that can be rolled back to: drivers (<name>.old), Wine engines (active + one other). Bottle snapshots: the newest 3 per bottle, for 3 days.
// Never touches games, saves, settings, the active engine or the current drivers.
func cleanUp(bottles: [String]) -> String {
    let fm = FileManager.default
    func age(_ p: String) -> TimeInterval { Date().timeIntervalSince((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? Date()) }
    func size(_ p: String) -> Int64 { Int64(shell("du -sk '\(p.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null | cut -f1").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    var freedKB: Int64 = 0, lines: [String] = []
    func remove(_ p: String, _ what: String? = nil) {
        guard fm.fileExists(atPath: p) else { return }
        let s = size(p); if (try? fm.removeItem(atPath: p)) != nil { freedKB += s; if let w = what { lines.append(w) } }
    }
    func clear(_ dir: String, olderThanDays d: Double = 0, matching: (String) -> Bool = { _ in true }) {
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where matching(f) && age("\(dir)/\(f)") > d * 86400 { remove("\(dir)/\(f)") }
    }

    for b in bottles {
        let c = "\(bottlesDir)/\(b)/drive_c"
        clear("\(c)/windows/temp", olderThanDays: 1)
        for u in (try? fm.contentsOfDirectory(atPath: "\(c)/users")) ?? [] {
            let local = "\(c)/users/\(u)/AppData/Local"
            clear("\(local)/Temp", olderThanDays: 1)
            for app in (try? fm.contentsOfDirectory(atPath: local)) ?? [] {   // Unreal/Epic-style crash folders and rotated logs
                clear("\(local)/\(app)/Saved/Crashes", olderThanDays: 3)
                clear("\(local)/\(app)/Saved/Logs", olderThanDays: 3) { $0.contains("backup") || $0.hasPrefix("EpicGamesUpdater-") }
            }
        }
        let steam = "\(c)/Program Files (x86)/Steam"
        clear("\(steam)/dumps", olderThanDays: 3)
        clear("\(steam)/logs", olderThanDays: 3) { $0.hasSuffix(".previous.txt") }
        clear("\(bottlesDir)/\(b)/installers", olderThanDays: 1)                       // store installers, once their client is in
        clear("\(c)/installers", olderThanDays: 1)
        let staged = "\(c)/ProgramData/Epic/EpicGamesLauncher/Data/Update/Install"     // Epic's self-update, already moved into place
        if fm.fileExists(atPath: "\(c)/ProgramData/Epic/EpicGamesLauncher/Data/Launcher.manifest"), age(staged) > 86400 { remove(staged) }
    }

    // Snapshots: the newest 3 of each bottle, none older than 3 days (item 26; this used to keep the newest two of all bottles together).
    for b in bottles { for n in Model.pruneSnapshots(b) { lines.append("older snapshot \(n)") } }

    // Engines: the active one plus one other (the most recently installed) as the previous version.
    let active = ((wineBin as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent   // …/engines/<name>/wswine.bundle
    let activeName = ((active as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let others = ((try? fm.contentsOfDirectory(atPath: support + "/engines")) ?? []).filter { $0.hasPrefix("WS12Wine") && $0 != activeName }
        .sorted { age(support + "/engines/" + $0) < age(support + "/engines/" + $1) }
    for e in others.dropFirst() { remove(support + "/engines/" + e, "older engine \(e)") }

    // Drivers keep exactly one previous version (<name>.old, made by the updater); anything older than that is dropped.
    for d in (try? fm.contentsOfDirectory(atPath: driversDir)) ?? [] where d.hasSuffix(".old.old") || d.hasSuffix(".bad") && age("\(driversDir)/\(d)") > 30 * 86400 { remove("\(driversDir)/\(d)", "old driver copy \(d)") }

    // Download caches outside the app that only its own tools fill.
    clear(NSHomeDirectory() + "/.cache/winetricks", olderThanDays: 30)
    if !isTestBuild, fm.fileExists(atPath: "/opt/homebrew/bin/brew") {   // never from a test build: brew cleanup acts on the real Homebrew
        let before = size(NSHomeDirectory() + "/Library/Caches/Homebrew")
        _ = shell("/opt/homebrew/bin/brew cleanup -s --prune=30 >/dev/null 2>&1")
        freedKB += max(0, before - size(NSHomeDirectory() + "/Library/Caches/Homebrew"))
    }
    // The app's own log: keep the last 2 MB once it passes 5 MB.
    let logPath = NSHomeDirectory() + "/Library/Logs/\(appDataName).log"
    if let d = fm.contents(atPath: logPath), d.count > 5_000_000 { try? d.suffix(2_000_000).write(to: URL(fileURLWithPath: logPath)); freedKB += Int64(d.count - 2_000_000) / 1024 }

    fm.createFile(atPath: support + "/.cleanup", contents: nil)
    let mb = freedKB / 1024
    return mb < 1 && lines.isEmpty ? "Clean up: nothing to remove.\n" : "Clean up: freed \(mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB")" + (lines.isEmpty ? "" : " (" + lines.joined(separator: ", ") + ")") + ".\n"
}

extension Model {
    func runCleanUp(silentIfNothing: Bool = false) {
        let b = bottles
        Task.detached { let r = cleanUp(bottles: b); await MainActor.run { if !(silentIfNothing && r.contains("nothing")) { self.log += r } } }
    }
    // Once a day, in the background.
    func dailyCleanUp() {
        guard UserDefaults.standard.object(forKey: "dailyCleanup") == nil || UserDefaults.standard.bool(forKey: "dailyCleanup") else { return }
        let stamp = support + "/.cleanup"
        if let m = (try? FileManager.default.attributesOfItem(atPath: stamp))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 86400 { return }
        runCleanUp(silentIfNothing: true)
    }
}
