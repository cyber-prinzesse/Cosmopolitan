import SwiftUI

// §8.4 Bottles on external drives: the bottle folder becomes a symlink to <drive>/Cosmopolitan Bottles/<name>, so every path in the app
// keeps working. An unplugged drive just hides the bottle (drive_c missing) — nothing breaks, it returns when the drive does.
extension Model {
    func externalVolumes() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { "/Volumes/\($0)" }
            .filter { v in (try? URL(fileURLWithPath: v).resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsReadOnlyKey]))
                .map { $0.volumeIsInternal == false && $0.volumeIsReadOnly == false } ?? false }
    }
    func moveBottle(to volume: String) {
        let name = selected, src = "\(bottlesDir)/\(name)", dstDir = "\(volume)/\(appDataName) Bottles", dst = "\(dstDir)/\(name)"
        guard !name.isEmpty, !FileManager.default.fileExists(atPath: dst) else { log += "Move: \(dst) already exists.\n"; return }
        guard sh("ps -axo command= | grep -c '\\.exe'").hasPrefix("0") else { log += "Move: quit Steam and games in this bottle first.\n"; return }
        busy = true; log += "Moving \(name) to \(volume)… (copy, verify, then replace the original with a link)\n"
        Task.detached {
            let r = shell("mkdir -p '\(dstDir)' && ditto '\(src)' '\(dst)' 2>&1 | tail -1 && [ -d '\(dst)/drive_c' ] && rm -rf '\(src)' && ln -s '\(dst)' '\(src)' && echo moved")
            await MainActor.run { self.busy = false; self.log += r.hasSuffix("moved") ? "Moved \(name) to \(dst); the bottle hides while the drive is unplugged.\n" : "Move failed: \(r)\n"; self.refresh() }
        }
    }
    func unpluggedBottles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bottlesDir)) ?? []).filter { b in
            let p = "\(bottlesDir)/\(b)"; return !b.hasPrefix(".") && (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil && !FileManager.default.fileExists(atPath: p + "/drive_c") }
    }
}
