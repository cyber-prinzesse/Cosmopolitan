import SwiftUI

// §5.5 Cloud saves for non-Steam programs (Steam games already have Steam Cloud): the game's save folders inside the bottle are mirrored to
// iCloud Drive › Cosmopolitan Saves › <program>. Newer side wins: pulled before launch, pushed when the program exits. Opt-in: CLOUD_SAVES=1.
extension Model {
    var cloudRoot: String { NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/\(appDataName) Saves" }
    // Where Windows programs keep saves: AppData Local/LocalLow/Roaming/<name>, Documents/My Games/<name>, Saved Games/<name>, and the program's own folder's "Saves".
    func saveFolders(_ exe: String) -> [String] {
        let name = appName(exe), u = "\(bottlesDir)/\(selected)/drive_c/users/\(NSUserName())", fm = FileManager.default
        var cands = ["\(u)/AppData/Local/\(name)", "\(u)/AppData/LocalLow/\(name)", "\(u)/AppData/Roaming/\(name)", "\(u)/Documents/My Games/\(name)", "\(u)/Saved Games/\(name)", (exe as NSString).deletingLastPathComponent + "/Saves", (exe as NSString).deletingLastPathComponent + "/save"]
        for base in ["\(u)/AppData/Local", "\(u)/AppData/LocalLow", "\(u)/AppData/Roaming", "\(u)/Documents/My Games", "\(u)/Saved Games"] {
            for d in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where d.localizedCaseInsensitiveContains(name.components(separatedBy: " ").first ?? name) { cands.append("\(base)/\(d)") }
        }
        return Array(Set(cands.filter { fm.fileExists(atPath: $0) })).sorted()
    }
    func cloudSync(_ exe: String, phase: String) {   // phase: "pull" before launch, "push" after exit
        guard options(exe)["CLOUD_SAVES"] == "1", steamGames[exe] == nil else { return }
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs") else { log += "Cloud saves: iCloud Drive is not enabled on this Mac.\n"; return }
        let folders = saveFolders(exe)
        guard !folders.isEmpty else { log += "Cloud saves: no save folder found yet for \(appName(exe)) (it appears after the first save).\n"; return }
        let dst = "\(cloudRoot)/\(appName(exe).replacingOccurrences(of: "/", with: "-"))"
        try? FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        for f in folders {
            let tag = f.replacingOccurrences(of: "\(bottlesDir)/\(selected)/drive_c/", with: "").replacingOccurrences(of: "/", with: "_")
            let cloud = "\(dst)/\(tag)"
            // rsync --update copies only files newer on the source side, in the chosen direction.
            let r = phase == "pull" ? sh("[ -d '\(cloud)' ] && rsync -a --update '\(cloud)/' '\(f)/' 2>&1 | tail -1") : sh("mkdir -p '\(cloud)' && rsync -a --update '\(f)/' '\(cloud)/' 2>&1 | tail -1")
            if !r.isEmpty { log += "Cloud saves: \(r)\n" }
        }
        log += "Cloud saves: \(phase == "pull" ? "pulled newer saves from" : "pushed saves to") iCloud Drive for \(appName(exe)) (\(folders.count) folder\(folders.count == 1 ? "" : "s")).\n"
    }
}
