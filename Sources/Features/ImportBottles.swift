import SwiftUI

extension Model {
    // §9.3 Import: bottles from Whisky, CrossOver and Sikarugir wrappers. Originals are never touched: the prefix is APFS-cloned in.
    func importableBottles() -> [(label: String, path: String)] {
        let h = NSHomeDirectory(), fm = FileManager.default
        var out: [(String, String)] = []
        for dir in ["\(h)/Library/Containers/com.isaacmarovitz.Whisky/Bottles", "\(h)/Library/Application Support/com.isaacmarovitz.Whisky/Bottles"] {
            for b in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where fm.fileExists(atPath: "\(dir)/\(b)/drive_c") {
                let name = (try? String(contentsOfFile: "\(dir)/\(b)/Metadata.plist", encoding: .utf8))?.components(separatedBy: "<key>Name</key>").dropFirst().first?.components(separatedBy: "<string>").dropFirst().first?.components(separatedBy: "</string>").first ?? b
                out.append(("Whisky: \(name)", "\(dir)/\(b)")) }
        }
        let cx = "\(h)/Library/Application Support/CrossOver/Bottles"
        for b in (try? fm.contentsOfDirectory(atPath: cx)) ?? [] where fm.fileExists(atPath: "\(cx)/\(b)/drive_c") { out.append(("CrossOver: \(b)", "\(cx)/\(b)")) }
        for root in ["\(h)/Applications/Sikarugir", "/Applications/Sikarugir", "\(h)/Applications"] {
            for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where a.hasSuffix(".app") && fm.fileExists(atPath: "\(root)/\(a)/Contents/SharedSupport/prefix/drive_c") { out.append(("Sikarugir: \((a as NSString).deletingPathExtension)", "\(root)/\(a)/Contents/SharedSupport/prefix")) }
        }
        return out
    }
    func importBottle(_ src: String, as name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-"), dst = "\(bottlesDir)/\(safe)"
        guard !FileManager.default.fileExists(atPath: dst) else { log += "Import: a bottle named \(safe) already exists.\n"; return }
        busy = true; log += "Importing \(src) → \(safe) (APFS clone, original untouched)…\n"
        Task.detached {
            let r = shell("cp -cR \(shq("\(src)")) \(shq("\(dst)")) 2>&1 | tail -1; rm -f \(shq("\(dst)/dosdevices/z:"))")   // imported bottles start restricted too
            await MainActor.run { self.busy = false; self.log += r.isEmpty ? "Imported \(safe). Controller defaults apply on first Repair.\n" : "Import: \(r)\n"; self.refresh(); self.selected = safe; self.scan() }
        }
    }
}
