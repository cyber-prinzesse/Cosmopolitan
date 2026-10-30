import SwiftUI

extension Model {
    // Find apps: every folder under C: that holds a real exe, not just Program Files. Results persist in <bottle>/cosmopolitan.apps.
    func findApps() {
        guard !selected.isEmpty else { return }
        let c = "\(bottlesDir)/\(selected)/drive_c", fm = FileManager.default
        let skipDirs = ["windows", "common files", "programdata", "temp", "steamapps", "redist", "_commonredist", "directx", "vcredist", "microsoft", "internet explorer", "windows nt", "windows media player", "windows defender", "wine", "windowsapps", "bin", "cache"]
        var best: [String: (String, Int)] = [:]   // folder -> (largest exe, size)
        guard let en = fm.enumerator(at: URL(fileURLWithPath: c), includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for case let u as URL in en {
            let rv = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
            if rv?.isSymbolicLink == true { en.skipDescendants(); continue }   // users/*/Desktop etc. point at the Mac home
            if rv?.isDirectory == true {
                let n = u.lastPathComponent.lowercased()
                if en.level > 5 || skipDirs.contains(where: { n.hasPrefix($0) }) { en.skipDescendants() }   // prefix: "Microsoft GameInput", "DirectX Redist"…
                continue
            }
            let n = u.lastPathComponent.lowercased()
            guard n.hasSuffix(".exe"), !skipExes.contains(where: { n.contains($0) }) else { continue }
            let dir = u.deletingLastPathComponent().path, size = rv?.fileSize ?? 0
            if size > (best[dir]?.1 ?? 0) { best[dir] = (u.path, size) }
        }
        let new = best.values.map { $0.0 }.filter { !programs.contains($0) }.sorted()
        let listPath = "\(bottlesDir)/\(selected)/cosmopolitan.apps"
        let old = ((try? String(contentsOfFile: listPath, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        try? Set(old + new).sorted().joined(separator: "\n").write(toFile: listPath, atomically: true, encoding: .utf8)
        let out = "Find apps: \(new.count) new program(s)\n" + new.map { "  C:" + $0.dropFirst(c.count).replacingOccurrences(of: "/", with: "\\") + "\n" }.joined()
        logToFile(out); log += out
        scan()
    }
}
