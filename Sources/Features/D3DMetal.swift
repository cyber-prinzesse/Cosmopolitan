import SwiftUI

// What a D3DMetal folder is: version from the framework's own Info.plist, features from the settings compiled into it, and the Game
// Porting Toolkit it came from (the first line of Apple's Read Me copied beside it).
struct D3DMetalInfo: Sendable {
    let version: String; let features: Set<String>; let source: String
    var pretty: String { version.replacingOccurrences(of: "b", with: " beta ") }
    var isBeta: Bool { version.contains("b") }
    var major: Int { Int(version.prefix { $0.isNumber }) ?? 0 }
}

extension Model {
    // D3DMetal: Apple's proprietary toolkit. Never fetched by Cosmopolitan: you pick your own Game Porting Toolkit download. Gated on Apple's
    // license, copied unmodified under Application Support. The installed version is never replaced or removed without a backup.
    nonisolated static let d3dmetalFeatureNames = ["D3DM_MTL4": "the Metal 4 backend", "D3DM_MAX_FPS": "the 60 fps battery cap for Direct3D 12",
                                                   "D3DM_ENABLE_METALFX": "DLSS-to-MetalFX upscaling", "D3DM_SUPPORT_DXR": "DirectX ray tracing"]
    // `folder` holds external/D3DMetal.framework (an installed renderer folder, or the redist/lib folder of a toolkit download).
    nonisolated static func d3dmetalInfo(_ folder: String, readMe: String? = nil) -> D3DMetalInfo? {
        let fw = folder + "/external/D3DMetal.framework"
        guard let plist = NSDictionary(contentsOfFile: fw + "/Versions/A/Resources/Info.plist") ?? NSDictionary(contentsOfFile: fw + "/Resources/Info.plist"),
              let v = plist["CFBundleShortVersionString"] as? String else { return nil }
        let bin = (try? Data(contentsOf: URL(fileURLWithPath: fw + "/D3DMetal"), options: .alwaysMapped)) ?? Data()
        let features = Set(d3dmetalFeatureNames.keys.filter { bin.range(of: Data($0.utf8)) != nil })
        let rm = readMe ?? folder + "/Read Me.rtf"
        let title = (try? NSAttributedString(url: URL(fileURLWithPath: rm), options: [:], documentAttributes: nil))?.string
            .components(separatedBy: "\n").first?.replacingOccurrences(of: " README", with: "")
        return D3DMetalInfo(version: v, features: features, source: title ?? "your Game Porting Toolkit download")
    }
    // "4.0b3" < "4.0" < "4.1": numbers first, a beta sorts before its release.
    nonisolated static func d3dmetalOlder(_ a: String, than b: String) -> Bool {
        func key(_ v: String) -> [Int] {
            let parts = v.components(separatedBy: "b"), nums = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            return (nums + [0, 0, 0]).prefix(3) + (parts.count > 1 ? [0, Int(parts[1]) ?? 0] : [1, 0])
        }
        return key(a).lexicographicallyPrecedes(key(b))
    }
    var d3dmetalNow: D3DMetalInfo? { Model.d3dmetalInfo(driversDir + "/d3dmetal") }

    func acceptD3DMetal() {
        let h = licenseHash(); guard d3dmetalInstalled(), !h.isEmpty else { log += "D3DMetal: not fully installed or Apple's License file missing; nothing accepted.\n"; return }
        let f = ISO8601DateFormatter(); try? "{\"accepted\":\"\(f.string(from: Date()))\",\"sha256\":\"\(h)\"}".write(toFile: d3dmetalAcceptFile, atomically: true, encoding: .utf8)
        d3dmetalOK = checkD3DMetalAccepted(); log += d3dmetalOK ? "D3DMetal: Apple's license accepted; Direct3D 12 games can use it now.\n" : "D3DMetal: could not record acceptance.\n"
        loadSettings(); verifyAll()
    }
    // Moves the installed D3DMetal aside as renderer/d3dmetal@<version> (never deleted). Returns the backup path.
    @discardableResult func backUpD3DMetal() -> String? {
        let dst = driversDir + "/d3dmetal"
        guard FileManager.default.fileExists(atPath: dst) else { return nil }
        var b = driversDir + "/d3dmetal@" + (d3dmetalNow?.version ?? "unknown")
        if FileManager.default.fileExists(atPath: b) { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; b += "-" + f.string(from: Date()) }
        guard (try? FileManager.default.moveItem(atPath: dst, toPath: b)) != nil else { return nil }
        return b
    }
    func removeD3DMetal() {
        let b = backUpD3DMetal(); try? FileManager.default.removeItem(atPath: d3dmetalAcceptFile)
        d3dmetalOK = false; log += "D3DMetal removed and license acceptance withdrawn" + (b.map { " (kept at \($0))" } ?? "") + ".\n"; loadSettings(); verifyAll()
    }
    // Accepts Apple's GPTK .dmg (mounted read-only here, detached afterwards), a mounted volume, or an extracted folder. If the incoming
    // version is older than the installed one or lacks features it has, nothing changes without a yes (dialog, or `confirmed` from --yes).
    @discardableResult func installD3DMetal(from picked: String, confirmed: Bool = false) -> Bool {
        var root = picked, mount = ""
        // Already open in Finder (double-clicked): a second attach fails "Resource busy", so use that mount and leave it attached.
        let open = picked.lowercased().hasSuffix(".dmg") ? sh("hdiutil info | awk -F'\\t' -v img=\(shq("\(picked)")) 'index($0,\"image-path\")==1{hit=(substr($0,index($0,\": \")+2)==img)} /^=+$/{hit=0} hit&&$3~/^\\/Volumes\\//{print $3; exit}'").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !open.isEmpty { root = open }
        else if picked.lowercased().hasSuffix(".dmg") {
            mount = NSTemporaryDirectory() + "cosmo-gptk-\(ProcessInfo.processInfo.processIdentifier)"
            let r = sh("mkdir -p \(shq("\(mount)")) && hdiutil attach -nobrowse -readonly -noverify -mountpoint \(shq("\(mount)")) \(shq("\(picked)")) 2>&1 | tail -1")
            guard FileManager.default.fileExists(atPath: mount), !r.contains("failed") else { log += "D3DMetal: could not mount \(picked): \(r)\n"; return false }
            root = mount
        }
        defer { if !mount.isEmpty { _ = sh("hdiutil detach \(shq("\(mount)")) -quiet; rmdir \(shq("\(mount)")) 2>/dev/null") } }
        // Find external/D3DMetal.framework and the sibling wine/ folder; Apple's License and Read Me sit at the image root.
        guard let en = FileManager.default.enumerator(atPath: root) else { return false }
        var ext = "", lic: [String] = []
        for case let p as String in en {
            if en.level > 6 { en.skipDescendants(); continue }
            if p.hasSuffix("external/D3DMetal.framework") { ext = "\(root)/\((p as NSString).deletingLastPathComponent)" }
            if ["License.pdf", "License.rtf", "Read Me.rtf", "Acknowledgements.rtf"].contains((p as NSString).lastPathComponent) { lic.append("\(root)/\(p)") }
        }
        guard !ext.isEmpty else { log += "D3DMetal: no external/D3DMetal.framework found under \(picked)\n"; return false }
        guard lic.contains(where: { $0.hasSuffix("License.pdf") || $0.hasSuffix("License.rtf") }) else { log += "D3DMetal: Apple's License file not found in this download; refusing to install without it.\n"; return false }
        let lib = (ext as NSString).deletingLastPathComponent, dst = driversDir + "/d3dmetal"
        let incoming = Model.d3dmetalInfo(lib, readMe: lic.first { $0.hasSuffix("Read Me.rtf") }), current = d3dmetalNow
        if let cur = current, let inc = incoming {
            let lost = cur.features.subtracting(inc.features).sorted().map { Model.d3dmetalFeatureNames[$0] ?? $0 }
            if Model.d3dmetalOlder(inc.version, than: cur.version) || !lost.isEmpty {
                let msg = "This replaces D3DMetal \(cur.pretty) with \(inc.pretty)." + (lost.isEmpty ? "" : " You lose " + lost.joined(separator: ", ") + ".") + " \(cur.pretty) is kept as a backup."
                if !confirmed {
                    if cliMode { log += "D3DMetal: \(msg) Nothing changed; run again with --yes to replace it.\n"; return false }
                    let a = NSAlert(); a.messageText = "Replace D3DMetal \(cur.pretty) with \(inc.pretty)?"; a.informativeText = msg
                    a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Keep \(cur.pretty)")
                    guard a.runModal() == .alertFirstButtonReturn else { log += "D3DMetal: kept \(cur.pretty).\n"; return false }
                }
                log += "D3DMetal: \(msg)\n"
            }
        }
        if let b = backUpD3DMetal() { log += "D3DMetal: previous version kept at \(b)\n" }   // always, upgrades too; never deleted
        _ = sh("mkdir -p \(shq("\(dst)")) && cp -R \(shq("\(ext)")) \(shq("\(dst)/external")) && cp -R \(shq("\(lib)/wine")) \(shq("\(dst)/wine"))")   // copied as-is, never modified
        for f in lic { _ = sh("cp \(shq("\(f)")) \(shq("\(dst)/")) 2>/dev/null") }
        d3dmetalOK = false; try? FileManager.default.removeItem(atPath: d3dmetalAcceptFile)
        let ok = d3dmetalInstalled()
        log += ok ? "D3DMetal \(incoming?.pretty ?? "") installed from \(incoming?.source ?? picked). Read and accept Apple's license to enable it.\n" : "D3DMetal: copy incomplete (need lib/external, lib/wine and the License file); nothing enabled.\n"
        updateStatus(); verifyAll()   // every game's launch check again: Direct3D 12 driver choice and the battery cap depend on this version
        return ok
    }
}
