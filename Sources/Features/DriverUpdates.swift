import SwiftUI

extension Model {
    // Driver updates from upstream GitHub releases: checked weekly, installed only when you confirm (Drivers › Update…) or with --update --install.
    // Nothing is replaced without asking; the previous version stays as <name>.old. D3DMetal is Apple's: only your own Game Porting Toolkit install.
    // ponytail: "installed" = the version file mentions the release tag; the Sikarugir builds carry extra commits on top of a tag.
    nonisolated static let driverSources = [("dxmt", "3Shain/dxmt", "-builtin.tar.gz"), ("dxvk", "Gcenx/DXVK-macOS", "-builtin.tar.gz"),
                                            ("dxvk3", "Sikarugir-App/dxvk", "-gplasync.tar.gz")]   // DXVK 3: the Sikarugir async build
    // Release archives without Wine's builtin marker (DXVK 3's x64/x32 PE files) get it stamped the way `winebuild --builtin` does:
    // "Wine builtin DLL" at 0x40, inside the DOS stub. Without it Wine treats them as native and the driver slots don't load them.
    nonisolated static func stampBuiltin(_ dir: String) {
        guard let en = FileManager.default.enumerator(atPath: dir) else { return }
        let mark = Data("Wine builtin DLL".utf8) + Data(count: 16)
        for case let p as String in en where p.lowercased().hasSuffix(".dll") {
            let f = dir + "/" + p
            guard var d = try? Data(contentsOf: URL(fileURLWithPath: f)), d.count > 0x60, d[0] == 0x4d, d[1] == 0x5a,
                  d.subdata(in: 0x3c..<0x40).withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) >= 0x60,
                  d.subdata(in: 0x40..<0x50) != mark.prefix(16) else { continue }
            d.replaceSubrange(0x40..<0x60, with: mark)
            try? d.write(to: URL(fileURLWithPath: f))
        }
    }
    nonisolated static func latestDriverTags() -> [(name: String, tag: String, url: String, installed: String)] {
        Model.driverSources.compactMap { name, repo, suffix in
            let j = shell("curl -s -m 8 https://api.github.com/repos/\(repo)/releases/latest")
            guard let tag = j.components(separatedBy: "\"tag_name\": \"").dropFirst().first?.components(separatedBy: "\"").first,
                  let url = j.components(separatedBy: "\"browser_download_url\": \"").dropFirst().map({ $0.components(separatedBy: "\"")[0] }).first(where: { $0.hasSuffix(suffix) }) else { return nil }
            let installed = ((try? String(contentsOfFile: "\(driversDir)/\(name)/version", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, tag, url, installed)
        }
    }
    nonisolated static func isCurrent(_ d: (name: String, tag: String, url: String, installed: String)) -> Bool {
        let num = d.tag.components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? d.tag   // "v1.10.3-20230507-repack" -> "v1.10.3"
        return d.installed.contains(num)
    }
    // All the work, off the main thread. Returns the log text. Previous versions are kept as <name>.old for a manual swap back.
    nonisolated static func performUpdate(install: Bool) -> String {
        var out = ""
        let list = latestDriverTags()
        if list.isEmpty { out += "Driver update: could not reach GitHub.\n" }
        for d in list {
            if isCurrent(d) { out += "✓ \(d.name) is current (\(d.installed), upstream \(d.tag))\n"; continue }
            guard install else { out += "• \(d.name): upstream \(d.tag) is available (installed: \(d.installed)). Nothing changed; Drivers › Update… asks before replacing it.\n"; continue }
            out += "↓ \(d.name) \(d.tag) — downloading…\n"
            let tmp = NSTemporaryDirectory() + "cosmo-\(d.name)-\(d.tag)"; _ = shell("rm -rf '\(tmp)'; mkdir -p '\(tmp)'")
            var found = shell("cd '\(tmp)' && curl -sL -m 300 -o pkg.tar.gz '\(d.url)' && tar xzf pkg.tar.gz && find . -type d -name x86_64-windows | head -1")
            // DXVK 3 releases use x64/x32 instead of Wine's folder names: rebuild them as a wine/ tree.
            let x64 = shell("cd '\(tmp)' && find . -type d -name x64 | head -1")
            if found.isEmpty, !x64.isEmpty {
                let p = (tmp + "/" + x64) as NSString
                _ = shell("mkdir -p '\(tmp)/wine' && cp -R '\(p)' '\(tmp)/wine/x86_64-windows' && { [ -d '\(p.deletingLastPathComponent)/x32' ] && cp -R '\(p.deletingLastPathComponent)/x32' '\(tmp)/wine/i386-windows' || true; }")
                found = "wine/x86_64-windows"
            }
            guard !found.isEmpty else { out += "✗ \(d.name): download or unpack failed\n"; continue }
            let src = (tmp + "/" + found) as NSString   // …/x86_64-windows -> its parent is the new 'wine' dir
            let dst = "\(driversDir)/\(d.name)"
            Model.stampBuiltin(src.deletingLastPathComponent)
            _ = shell("rm -rf '\(dst).old'; mv '\(dst)' '\(dst).old' 2>/dev/null; mkdir -p '\(dst)' && cp -R '\(src.deletingLastPathComponent)/.' '\(dst)/wine/' && printf '%s\\n' '\(d.tag)' > '\(dst)/version'; rm -rf '\(tmp)'")
            if FileManager.default.fileExists(atPath: dst + "/wine/x86_64-windows") { out += "✓ \(d.name) updated to \(d.tag) (previous kept as \(d.name).old)\n" }
            else { _ = shell("rm -rf '\(dst)'; mv '\(dst).old' '\(dst)'"); out += "✗ \(d.name): install failed, previous version restored\n" }
        }
        // No Sikarugir template or engine is fetched here any more: the template archive carries Apple's D3DMetal, and the Sikarugir
        // engine and drivers stay at their pinned versions (Components.swift) until upstream replacements pass the test suite.
        // D3DMetal is Apple's and is never fetched or synced automatically (license rule): the user installs it from Apple's own download via Drivers › D3DMetal….
        out += FileManager.default.fileExists(atPath: driversDir + "/d3dmetal/wine") ? (d3dmetalOK ? "✓ d3dmetal present, Apple's license accepted\n" : "• d3dmetal present, Apple's license not accepted yet (Drivers › D3DMetal…)\n") : "• d3dmetal not installed (optional, needed for Direct3D 12)\n"
        FileManager.default.createFile(atPath: support + "/.driver-check", contents: nil)
        return out
    }
}
