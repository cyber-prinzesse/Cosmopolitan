import SwiftUI
import AppKit

extension Model {
    // Find apps: every bottle's drive_c (and optionally an extra folder the user picks). Results persist in <bottle>/cosmopolitan.apps.
    // Idempotent: a second run adds nothing. Helpers (skipExes, crash handlers, REDprelauncher when the game exists) are never listed.
    // The Library then dedupes store manifests vs plain exes, Unreal bootstrap vs shipping, symlinks, and cross-bottle copies.
    func findApps(extraFolder: String? = nil) {
        var added = 0
        let targets = bottles.filter { FileManager.default.fileExists(atPath: "\(bottlesDir)/\($0)/drive_c") }
        for b in targets { added += findAppsInBottle(b) }
        if let extra = extraFolder, !extra.isEmpty {
            // External / picked folder: stage discoveries into the selected bottle's cosmopolitan.apps (or the first bottle).
            let b = selected.isEmpty ? (targets.first ?? "") : selected
            if !b.isEmpty { added += findAppsUnder(root: extra, bottle: b, persistRelativize: false) }
        }
        let out = "Find apps: \(added) new program(s) across \(targets.count) bottle\(targets.count == 1 ? "" : "s")"
            + (extraFolder.map { " (+ \($0))" } ?? "") + "\n"
        logToFile(out); log += out
        scan()
    }

    // Sheet / Advanced button: optional folder picker, then scan every bottle + that folder.
    func findAppsAskingFolder() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = "Optional: also search a folder outside the bottles (for example an external drive). Cancel skips it."
        p.prompt = "Scan this folder"
        if p.runModal() == .OK, let u = p.url { findApps(extraFolder: u.path) }
        else { findApps() }
    }

    @discardableResult
    func findAppsInBottle(_ bottle: String) -> Int {
        findAppsUnder(root: "\(bottlesDir)/\(bottle)/drive_c", bottle: bottle, persistRelativize: false)
    }

    // Walk root for .exe files; append new absolute paths to cosmopolitan.apps. Returns how many were new.
    @discardableResult
    func findAppsUnder(root: String, bottle: String, persistRelativize: Bool) -> Int {
        let fm = FileManager.default
        // Exact names (or Microsoft* / DirectX*): not "bin" as a prefix — that would skip Unreal's Binaries/Win64.
        let skipExact: Set<String> = ["windows", "common files", "programdata", "temp", "steamapps", "redist", "_commonredist",
                                      "internet explorer", "windows nt", "windows media player", "windows defender", "wine", "windowsapps",
                                      "bin", "cache", "cef", "crashpad", "easyanticheat", "battleye"]
        var best: [String: (String, Int)] = [:]   // folder -> (largest exe, size) — size from attributes only
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
                                     options: [.skipsHiddenFiles]) else { return 0 }
        for case let u as URL in en {
            let rv = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
            // Follow neither Mac home shortcuts nor bottle-internal link farms into a second copy of the same tree.
            if rv?.isSymbolicLink == true { en.skipDescendants(); continue }
            if rv?.isDirectory == true {
                let n = u.lastPathComponent.lowercased()
                if en.level > 5 || skipExact.contains(n) || n.hasPrefix("microsoft") || n.hasPrefix("directx") || n.hasPrefix("vcredist") { en.skipDescendants() }
                continue
            }
            let n = u.lastPathComponent.lowercased()
            guard n.hasSuffix(".exe"), !isHelperExe(u.path) else { continue }
            let dir = u.deletingLastPathComponent().path, size = rv?.fileSize ?? 0
            if size > (best[dir]?.1 ?? 0) { best[dir] = (u.path, size) }
        }
        let listPath = "\(bottlesDir)/\(bottle)/cosmopolitan.apps"
        let old = ((try? String(contentsOfFile: listPath, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        let oldReal = Set(old.map { realPath($0).lowercased() })
        var new: [String] = []
        for path in best.values.map(\.0).sorted() {
            let rp = realPath(path).lowercased()
            guard !oldReal.contains(rp) else { continue }
            // Also skip if programsIn / store scan already has this identity (idempotent vs rescan).
            new.append(path)
        }
        guard !new.isEmpty else { return 0 }
        try? (old + new).sorted().joined(separator: "\n").write(toFile: listPath, atomically: true, encoding: .utf8)
        for p in new {
            let shown = p.hasPrefix("\(bottlesDir)/\(bottle)/drive_c")
                ? "C:" + p.dropFirst("\(bottlesDir)/\(bottle)/drive_c".count).replacingOccurrences(of: "/", with: "\\")
                : p
            log += "  \(bottle): \(shown)\n"
        }
        return new.count
    }

    // Hidden tiles: identities the user removed from the Library. Survive rescans until they "Show again".
    var hiddenLibraryPath: String { support + "/cosmopolitan.hidden" }
    func hiddenLibraryIds() -> Set<String> {
        Set(((try? String(contentsOfFile: hiddenLibraryPath, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty })
    }
    func hideFromLibrary(_ exe: String) {
        let id = libraryIdentity(exe)
        var h = hiddenLibraryIds(); h.insert(id)
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        try? h.sorted().joined(separator: "\n").write(toFile: hiddenLibraryPath, atomically: true, encoding: .utf8)
        log += "Hidden \(appName(exe)) from the Library (Find apps / scan will keep it hidden).\n"
        scan()
    }
    func unhideFromLibrary(_ id: String) {
        var h = hiddenLibraryIds(); h.remove(id)
        try? h.sorted().joined(separator: "\n").write(toFile: hiddenLibraryPath, atomically: true, encoding: .utf8)
        scan()
    }
}
