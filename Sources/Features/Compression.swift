import SwiftUI

extension Model {
    // §8.3 Transparent APFS compression of one game's folder: files stay readable as-is; the OS decompresses on read. Refused while the game runs.
    func compressGame(_ exe: String) {
        let root: String = { if let r = exe.range(of: "/steamapps/common/") { let rest = exe[r.upperBound...]; if let s = rest.firstIndex(of: "/") { return String(exe[..<s]) } }; return (exe as NSString).deletingLastPathComponent }()
        guard !isRunning((exe as NSString).lastPathComponent) else { log += "Compress: \(appName(exe)) is running; quit it first.\n"; return }
        busy = true; log += "Compressing \(root) with APFS transparent compression (ditto --hfsCompression)… this reads and rewrites every file once.\n"
        Task.detached {
            // SEC-006: the original goes only after ditto itself succeeded (the old `ditto | tail` checked tail's status, so a failed
            // copy still deleted the game). Arguments, not shell text: game folder names come from Windows.
            let fm = FileManager.default, tmp = root + ".compressing"
            func kb() -> Int { Int(runTool("/usr/bin/du", ["-sk", root]).out.split(separator: "\t").first ?? "") ?? 0 }
            let before = kb()
            try? fm.removeItem(atPath: tmp)
            let d = runTool("/usr/bin/ditto", ["--hfsCompression", root, tmp])
            let r: String
            if d.status != 0 { try? fm.removeItem(atPath: tmp); r = "ditto failed (\(d.status)), nothing changed: \(d.out.split(separator: "\n").last ?? "")" }
            else if (try? fm.removeItem(atPath: root)) == nil || (try? fm.moveItem(atPath: tmp, toPath: root)) == nil { r = "could not swap in the compressed copy; it is at \(tmp)" }
            else { r = "" }
            let after = kb()
            await MainActor.run { self.busy = false; self.log += r.isEmpty ? "Compressed: \(before / 1024) MB → \(after / 1024) MB on disk.\n" : "Compress: \(r)\n"; self.scan() }
        }
    }
}
