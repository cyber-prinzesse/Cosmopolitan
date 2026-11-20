import SwiftUI

extension Model {
    // Driver updates from upstream GitHub releases: checked weekly, installed only when you confirm (Drivers › Update…) or with --update --install.
    // Nothing is replaced without asking; the previous version stays as <name>.old. D3DMetal is Apple's: only your own Game Porting Toolkit install.
    // ponytail: "installed" = the version file mentions the release tag; the Sikarugir builds carry extra commits on top of a tag.
    nonisolated static let driverSources = [("dxmt", "3Shain/dxmt", "-builtin.tar.gz", Pins.dxmt), ("dxvk", "Gcenx/DXVK-macOS", "-builtin.tar.gz", Pins.dxvk),
                                            ("dxvk3", "Sikarugir-App/dxvk", "-gplasync.tar.gz", Pins.dxvk3)]   // DXVK 3: the Sikarugir async build
    // SEC-003: what gets installed is either the pinned release (Pins, checked by fetchPinned) or, only from Drivers › Update…, the newest
    // upstream release whose file matches the SHA-256 digest GitHub publishes for that asset. No digest, no install.
    struct DriverRelease: Sendable { let name, tag, url, digest, installed: String; let pin: Pinned }
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
    private struct GHRelease: Decodable { let tag_name: String; let assets: [Asset]; struct Asset: Decodable { let name, browser_download_url: String; let digest: String? } }
    // Newest upstream release per driver, read from GitHub's API with JSONDecoder (no string cutting).
    nonisolated static func latestDriverTags() -> [DriverRelease] {
        Model.driverSources.compactMap { name, repo, suffix, pin in
            let api = (isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_DRIVER_API_\(name)"] : nil) ?? "https://api.github.com/repos/\(repo)/releases/latest"
            let r = runTool("/usr/bin/curl", ["-sf", "-m", "8", api])
            guard r.status == 0, let rel = try? JSONDecoder().decode(GHRelease.self, from: Data(r.out.utf8)),
                  let a = rel.assets.first(where: { $0.name.hasSuffix(suffix) }) else { return nil }
            return DriverRelease(name: name, tag: rel.tag_name, url: a.browser_download_url, digest: a.digest ?? "", installed: installedDriver(name), pin: pin)
        }
    }
    nonisolated static func installedDriver(_ name: String) -> String {
        ((try? String(contentsOfFile: "\(driversDir)/\(name)/version", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated static func isCurrent(_ installed: String, _ tag: String) -> Bool {
        let num = tag.components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? tag   // "v1.10.3-20230507-repack" -> "v1.10.3"
        return installed.contains(num)
    }
    nonisolated static func isCurrent(_ d: DriverRelease) -> Bool { isCurrent(d.installed, d.tag) }
    // "v0.81" vs pin "v0.80" -> true (numeric compare of the leading version, so 1.10.3 > 1.9); no digits -> false.
    nonisolated static func isNewer(_ installed: String, than tag: String) -> Bool {
        func num(_ s: String) -> String { String((s.components(separatedBy: CharacterSet(charactersIn: "-_ ")).first ?? s).drop { !$0.isNumber }) }
        let a = num(installed), b = num(tag)
        return !a.isEmpty && !b.isEmpty && a.compare(b, options: .numeric) == .orderedDescending
    }
    // Unpacks a verified archive and swaps it in as drivers/<name> (previous kept as <name>.old, put back if anything fails). No shell.
    nonisolated static func installDriver(_ name: String, archive: String, tag: String) -> String {
        let fm = FileManager.default, tmp = NSTemporaryDirectory() + "cosmo-\(name)-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: tmp) }
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        guard runTool("/usr/bin/tar", ["xzf", archive, "-C", tmp]).status == 0 else { return "✗ \(name): unpack failed; nothing changed\n" }
        let entries = (fm.enumerator(atPath: tmp)?.allObjects as? [String]) ?? []
        func dir(_ leaf: String) -> String? { entries.first { ($0 as NSString).lastPathComponent == leaf }.map { tmp + "/" + $0 } }
        var wine = dir("x86_64-windows").map { ($0 as NSString).deletingLastPathComponent }
        if wine == nil, let x64 = dir("x64") {   // DXVK 3 releases use x64/x32 instead of Wine's folder names: rebuild them as a wine/ tree
            let w = tmp + "/.wine", x32 = (x64 as NSString).deletingLastPathComponent + "/x32"
            try? fm.createDirectory(atPath: w, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: x64, toPath: w + "/x86_64-windows")
            if fm.fileExists(atPath: x32) { try? fm.copyItem(atPath: x32, toPath: w + "/i386-windows") }
            wine = w
        }
        guard let src = wine else { return "✗ \(name): no x86_64-windows folder in the archive; nothing changed\n" }
        Model.stampBuiltin(src)
        let dst = "\(driversDir)/\(name)", old = dst + ".old"
        try? fm.removeItem(atPath: old); try? fm.moveItem(atPath: dst, toPath: old)
        do {
            try fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
            try fm.copyItem(atPath: src, toPath: dst + "/wine")
            try (tag + "\n").write(toFile: dst + "/version", atomically: true, encoding: .utf8)
            guard fm.fileExists(atPath: dst + "/wine/x86_64-windows") else { throw CocoaError(.fileNoSuchFile) }
        } catch {
            try? fm.removeItem(atPath: dst); try? fm.moveItem(atPath: old, toPath: dst)
            return "✗ \(name): install failed, previous version restored\n"
        }
        return "✓ \(name) updated to \(tag) (previous kept as \(name).old)\n"
    }
    // All the work, off the main thread. Returns the log text. Previous versions are kept as <name>.old for a manual swap back.
    // newest: false (weekly check, --update --install) installs only the pinned release; true (Drivers › Update…, --update --install
    // --newest) installs the newest upstream release, but only if its file matches GitHub's digest for it.
    nonisolated static func performUpdate(install: Bool, newest: Bool = false) -> String {
        var out = ""
        let upstream = latestDriverTags()
        if upstream.isEmpty { out += "Driver update: could not reach GitHub (pinned releases can still install).\n" }
        for (name, _, _, pin) in Model.driverSources {
            let installed = installedDriver(name), up = upstream.first { $0.name == name }
            let target: (tag: String, url: String, sha: String)
            if newest, let up {
                guard up.digest.hasPrefix("sha256:") else { out += "✗ \(name): GitHub publishes no checksum for \(up.tag); not installed.\n"; continue }
                target = (up.tag, up.url, String(up.digest.dropFirst(7)))
            } else { target = (pin.version, pin.url, pin.sha256) }
            if let up, !newest, !isCurrent(installed, up.tag), up.tag != pin.version { out += "• \(name): upstream \(up.tag) is available; Drivers › Update… installs it after checking GitHub's checksum.\n" }
            if !newest, isNewer(installed, than: pin.version) { out += "✓ \(name) \(installed) is newer than the pinned \(pin.version); kept.\n"; continue }
            if isCurrent(installed, target.tag) { out += "✓ \(name) is current (\(installed), \(newest ? "upstream" : "pinned") \(target.tag))\n"; continue }
            guard install else { out += "• \(name): \(target.tag) is available (installed: \(installed)). Nothing changed.\n"; continue }
            out += "↓ \(name) \(target.tag) — downloading…\n"
            let p = Pinned(name: name, version: target.tag, file: "\(name)-\(target.tag).tar.gz", url: target.url, sha256: target.sha, license: pin.license, source: pin.source)
            guard let archive = fetchPinned(p, log: { out += $0 }) else { continue }   // verifies the SHA-256; a mismatch installs nothing
            out += installDriver(name, archive: archive, tag: target.tag)
        }
        // No Sikarugir template or engine is fetched here any more: the template archive carries Apple's D3DMetal, and the Sikarugir
        // engine and drivers stay at their pinned versions (Components.swift) until upstream replacements pass the test suite.
        // D3DMetal is Apple's and is never fetched or synced automatically (license rule): the user installs it from Apple's own download via Drivers › D3DMetal….
        out += FileManager.default.fileExists(atPath: driversDir + "/d3dmetal/wine") ? (d3dmetalOK ? "✓ d3dmetal present, Apple's license accepted\n" : "• d3dmetal present, Apple's license not accepted yet (Drivers › D3DMetal…)\n") : "• d3dmetal not installed (optional, needed for Direct3D 12)\n"
        FileManager.default.createFile(atPath: support + "/.driver-check", contents: nil)
        return out
    }
}
