import SwiftUI

// §7.11 Mod manager: a mod is a folder (or zip) whose layout mirrors the game folder. Installing copies it over the game while backing up every
// file it replaces; disabling restores those files; Wine paths are plain Unix paths, so nothing else is needed. State lives in <bottle>/mods/<program>/.
extension Model {
    func modsDir(_ exe: String) -> String { "\(bottlesDir)/\(selected)/mods/\(appName(exe).replacingOccurrences(of: "/", with: "-"))" }
    func gameRoot(_ exe: String) -> String {
        if let r = exe.range(of: "/steamapps/common/") { let rest = exe[r.upperBound...]; if let s = rest.firstIndex(of: "/") { return String(exe[..<s]) } }
        return (exe as NSString).deletingLastPathComponent
    }
    func mods(_ exe: String) -> [(name: String, enabled: Bool)] {
        ((try? FileManager.default.contentsOfDirectory(atPath: modsDir(exe))) ?? []).filter { !$0.hasPrefix(".") }.sorted().map { ($0, FileManager.default.fileExists(atPath: "\(modsDir(exe))/\($0)/.enabled")) }
    }
    func addMod(_ exe: String, from picked: String) {
        let name = ((picked as NSString).lastPathComponent as NSString).deletingPathExtension, dst = "\(modsDir(exe))/\(name)"
        try? FileManager.default.createDirectory(atPath: modsDir(exe), withIntermediateDirectories: true)
        let r = picked.lowercased().hasSuffix(".zip") ? sh("rm -rf \(shq("\(dst)")) && mkdir -p \(shq("\(dst)")) && ditto -x -k \(shq("\(picked)")) \(shq("\(dst)")) 2>&1 | tail -1") : sh("rm -rf \(shq("\(dst)")) && cp -R \(shq("\(picked)")) \(shq("\(dst)")) 2>&1 | tail -1")
        // A zip whose single top-level folder is just a wrapper (its name is NOT a folder of the game) is unwrapped so files line up with the game root.
        let top = ((try? FileManager.default.contentsOfDirectory(atPath: dst)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        if top.count == 1, let only = top.first, FileManager.default.fileExists(atPath: "\(dst)/\(only)/."), !FileManager.default.fileExists(atPath: "\(gameRoot(exe))/\(only)"), !only.contains(".") {
            _ = sh("cd \(shq("\(dst)")) && mv \(shq("\(only)")) .wrap && cp -R .wrap/. . && rm -rf .wrap __MACOSX")
        }
        log += r.isEmpty ? "Mod added: \(name) (disabled; enable it from the Mods sheet).\n" : "Mod add failed: \(r)\n"; artVersion += 1
    }
    func setMod(_ exe: String, _ name: String, enabled: Bool) {
        let mod = "\(modsDir(exe))/\(name)", root = gameRoot(exe), backup = "\(mod)/.backup"
        guard !isRunning((exe as NSString).lastPathComponent) else { log += "Mods: quit \(appName(exe)) first.\n"; return }
        let files = sh("cd \(shq("\(mod)")) && find . -type f ! -path './.backup/*' ! -name '.enabled' ! -name '.DS_Store' | sed 's|^\\./||'").split(separator: "\n").map(String.init)
        if enabled {
            snapshot("before enabling mod \(name)")
            for f in files {
                let target = "\(root)/\(f)"
                if FileManager.default.fileExists(atPath: target) { _ = sh("mkdir -p \"$(dirname \(shq("\(backup)/\(f)")))\" && cp -p \(shq("\(target)")) \(shq("\(backup)/\(f)"))") }
                _ = sh("mkdir -p \"$(dirname \(shq(target)))\" && cp -p \(shq("\(mod)/\(f)")) \(shq("\(target)"))")
            }
            FileManager.default.createFile(atPath: mod + "/.enabled", contents: nil)
            log += "Mod enabled: \(name) (\(files.count) files; originals backed up).\n"
        } else {
            for f in files {
                let target = "\(root)/\(f)"
                if FileManager.default.fileExists(atPath: "\(backup)/\(f)") { _ = sh("cp -p \(shq("\(backup)/\(f)")) \(shq("\(target)"))") } else { try? FileManager.default.removeItem(atPath: target) }
            }
            _ = sh("rm -rf \(shq("\(backup)")) \(shq("\(mod)/.enabled"))")
            log += "Mod disabled: \(name) (originals restored).\n"
        }
        artVersion += 1
    }
    func removeMod(_ exe: String, _ name: String) {
        if mods(exe).first(where: { $0.name == name })?.enabled == true { setMod(exe, name, enabled: false) }
        try? FileManager.default.removeItem(atPath: "\(modsDir(exe))/\(name)"); log += "Mod removed: \(name)\n"; artVersion += 1
    }
}
