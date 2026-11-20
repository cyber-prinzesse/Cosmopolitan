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
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { log += "Mod add refused: \"\(name)\" is not a usable folder name.\n"; return }
        guard !FileManager.default.fileExists(atPath: dst + "/.enabled") else { log += "Mod add refused: \(name) is enabled; disable it first (its backup holds the game's originals).\n"; return }
        if picked.lowercased().hasSuffix(".zip") {   // zip-slip: an entry that is absolute or climbs out with ".." is never extracted
            let list = runTool("/usr/bin/zipinfo", ["-1", picked])
            let bad = list.out.split(separator: "\n").first { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") || $0.split(separator: "\\").contains("..") }
            guard list.status == 0, bad == nil else { log += "Mod add refused: \(name).zip \(bad.map { "has a path outside its folder: \($0)" } ?? "could not be read").\n"; return }
        }
        try? FileManager.default.createDirectory(atPath: modsDir(exe), withIntermediateDirectories: true)
        let r = picked.lowercased().hasSuffix(".zip") ? sh("rm -rf \(shq("\(dst)")) && mkdir -p \(shq("\(dst)")) && ditto -x -k \(shq("\(picked)")) \(shq("\(dst)")) 2>&1 | tail -1") : sh("rm -rf \(shq("\(dst)")) && cp -R \(shq("\(picked)")) \(shq("\(dst)")) 2>&1 | tail -1")
        // A zip whose single top-level folder is just a wrapper (its name is NOT a folder of the game) is unwrapped so files line up with the game root.
        let top = ((try? FileManager.default.contentsOfDirectory(atPath: dst)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        if top.count == 1, let only = top.first, FileManager.default.fileExists(atPath: "\(dst)/\(only)/."), !FileManager.default.fileExists(atPath: "\(gameRoot(exe))/\(only)"), !only.contains(".") {
            _ = sh("cd \(shq("\(dst)")) && mv \(shq("\(only)")) .wrap && cp -R .wrap/. . && rm -rf .wrap __MACOSX")
        }
        log += r.isEmpty ? "Mod added: \(name) (disabled; enable it from the Mods sheet).\n" : "Mod add failed: \(r)\n"; artVersion += 1
    }
    @discardableResult func setMod(_ exe: String, _ name: String, enabled: Bool) -> Bool {
        let mod = "\(modsDir(exe))/\(name)", root = gameRoot(exe), backup = "\(mod)/.backup"
        guard !isRunning((exe as NSString).lastPathComponent) else { log += "Mods: quit \(appName(exe)) first.\n"; return false }
        let fm = FileManager.default; var failed: [String] = []
        func copy(_ from: String, _ to: String) -> Bool {   // argv, status checked (a full disk or a locked file must not pass as success)
            try? fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            return runTool("/bin/cp", ["-p", from, to]).status == 0
        }
        let files = sh("cd \(shq("\(mod)")) && find . -type f ! -path './.backup/*' ! -name '.enabled' ! -name '.installed' ! -name '.DS_Store' | sed 's|^\\./||'").split(separator: "\n").map(String.init)
        if enabled {
            guard !fm.fileExists(atPath: mod + "/.enabled") else { log += "Mod already enabled: \(name).\n"; return true }   // a 2nd enable would back the mod's own files up over the originals
            snapshot("before enabling mod \(name)")
            var installed: [String] = []
            for f in files {
                let target = "\(root)/\(f)"
                if fm.fileExists(atPath: target), !copy(target, "\(backup)/\(f)") {   // no complete backup: original left alone, partial copy dropped
                    try? fm.removeItem(atPath: "\(backup)/\(f)"); failed.append(f); continue
                }
                installed.append(f)   // from here on disable owns this file (restore it, or delete it if the game had none)
                if !copy("\(mod)/\(f)", target) { failed.append(f) }
            }
            try? installed.joined(separator: "\n").write(toFile: mod + "/.installed", atomically: true, encoding: .utf8)
            fm.createFile(atPath: mod + "/.enabled", contents: nil)
            log += failed.isEmpty ? "Mod enabled: \(name) (\(files.count) files; originals backed up).\n"
                                  : "Mod enabled with problems: \(name) — \(failed.count) of \(files.count) files not installed (\(failed.prefix(3).joined(separator: ", "))); originals untouched for those.\n"
        } else {
            let list = (try? String(contentsOfFile: mod + "/.installed", encoding: .utf8)).map { $0.split(separator: "\n").map(String.init) }
            for f in list ?? files {
                let target = "\(root)/\(f)"
                if fm.fileExists(atPath: "\(backup)/\(f)") { if !copy("\(backup)/\(f)", target) { failed.append(f) } } else { try? fm.removeItem(atPath: target) }
            }
            if failed.isEmpty {
                try? fm.removeItem(atPath: backup); try? fm.removeItem(atPath: mod + "/.enabled"); try? fm.removeItem(atPath: mod + "/.installed")
                log += "Mod disabled: \(name) (originals restored).\n"
            } else {   // the backup is the only copy of these originals: keep it, and keep the mod marked enabled so a retry restores them
                log += "Mod disable incomplete: \(name) — \(failed.count) original\(failed.count == 1 ? "" : "s") could not be restored (\(failed.prefix(3).joined(separator: ", "))); kept in mods/\(name)/.backup. Free some space and try again.\n"
            }
        }
        artVersion += 1
        return failed.isEmpty
    }
    func removeMod(_ exe: String, _ name: String) {
        if mods(exe).first(where: { $0.name == name })?.enabled == true, !setMod(exe, name, enabled: false) { log += "Mod not removed: \(name) (its backup still holds originals).\n"; return }
        try? FileManager.default.removeItem(atPath: "\(modsDir(exe))/\(name)"); log += "Mod removed: \(name)\n"; artVersion += 1
    }
}
