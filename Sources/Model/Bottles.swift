import SwiftUI

extension Model {
    // Item 31: a new bottle is one clonefile of a clean template, made from the first bottle created with this engine version and Windows
    // version before anything was installed in it (seconds instead of a minute). A new engine version gets a fresh template, and older ones go.
    nonisolated static var templatesDir: String { support + "/templates" }
    nonisolated static func templateKey(_ winver: String) -> String {
        let v = (isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_ENGINE_VERSION"] : nil) ?? shell("'\(wineBin)' --version 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(engineName) \(v) \(winver)".replacingOccurrences(of: "/", with: "-")
    }
    func saveTemplate(_ name: String, _ key: String) {
        let fm = FileManager.default, dir = Model.templatesDir, src = "\(bottlesDir)/\(name)"
        guard fm.fileExists(atPath: src + "/drive_c/windows/mono") else { return }   // only a complete bottle (Wine Mono in) becomes the template
        guard fm.fileExists(atPath: src + "/system.reg"), prefixServer(src) == nil else { return }   // and only with its registry on disk
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where old != key && old.hasSuffix(" " + (key.split(separator: " ").last.map(String.init) ?? "")) { try? fm.removeItem(atPath: "\(dir)/\(old)") }
        if !fm.fileExists(atPath: "\(dir)/\(key)"), clonefile(src, "\(dir)/\(key)", UInt32(CLONE_NOFOLLOW)) == 0 { log += "Saved a clean template (\(key)); new bottles are made from it in seconds.\n" }
    }
    func createBottle(_ name: String, then: (@MainActor () -> Void)? = nil) {
        let t = template == "auto" ? "win10" : template, key = Model.templateKey(t), tpl = "\(Model.templatesDir)/\(key)"
        if FileManager.default.fileExists(atPath: tpl + "/drive_c"), clonefile(tpl, "\(bottlesDir)/\(name)", UInt32(CLONE_NOFOLLOW)) == 0 {
            log += "Bottle \(name): made from the clean template (\(key)).\n"; refresh(); then?(); return
        }
        try? FileManager.default.createDirectory(atPath: "\(bottlesDir)/\(name)", withIntermediateDirectories: true)
        // mscoree/mshtml off: skips Mono/Gecko download prompts during creation.
        // No driver slots for wineboot: with them active it copies the drivers' DLLs into system32/syswow64 as if they were Wine's own.
        PreparingWindow.begin(bottle: name)   // native preparing chrome (GUI only; skipped in cliMode)
        wine(name, ["wineboot", "-u"], env: ["WINEDLLOVERRIDES": "mscoree,mshtml="], drivers: []) {
            PreparingWindow.end()
            // Controllers via SDL as XInput gamepads (raw HID only reaches DirectInput, and Steam Input can't drive it under Wine).
            self.wine(name, ["reg", "add", "HKLM\\System\\CurrentControlSet\\Services\\winebus", "/v", "DisableHidraw", "/t", "REG_DWORD", "/d", "1", "/f"]) {
                self.wine(name, ["winecfg", "-v", t]) {
                    // Restricted by default: no Z: (whole Mac) drive. Programs see C: only. FULL_DISK=1 in cosmopolitan.env restores Z: for a bottle.
                    try? FileManager.default.removeItem(atPath: "\(bottlesDir)/\(name)/dosdevices/z:")
                    self.log += "Bottle \(name): restricted to C: (no access to the Mac's files). Add FULL_DISK=1 to its cosmopolitan.env to widen it.\n"
                    let pfx = "\(bottlesDir)/\(name)"   // .NET: Wine Mono from WineHQ (pinned), verified by running the probe program
                    Task.detached { _ = Model.installWineMono(pfx) { s in Task { @MainActor in self.log += s } }
                        // Wine writes the registry to disk when the bottle's wineserver exits: wait for that (at most 30 s) before it can become the template.
                        _ = shell("env WINEPREFIX='\(pfx)' perl -e 'alarm 30; exec @ARGV' -- '\((wineBin as NSString).deletingLastPathComponent)/wineserver' -w 2>/dev/null; true")
                        await MainActor.run { self.saveTemplate(name, key); then?() } } } } }
    }

    func deleteBottle() {   // to Trash, so it's recoverable
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: "\(bottlesDir)/\(selected)"), resultingItemURL: nil)
        log += "Moved \(selected) to Trash.\n"; refresh()
    }

    // Backup = instant APFS clone (no extra disk space until files change).
    func backupBottle() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        exec("/bin/cp", ["-cR", "\(bottlesDir)/\(selected)", "\(bottlesDir)/\(selected)-backup-\(f.string(from: Date()))"])
    }

    func setRetina(_ on: Bool) {
        wine(selected, ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", "RetinaMode", "/t", "REG_SZ", "/d", on ? "y" : "n", "/f"])
    }

    func archiveBottle() {
        let p = NSSavePanel(); p.nameFieldStringValue = selected + ".tar"
        if p.runModal() == .OK, let u = p.url { exec("/usr/bin/tar", ["-cf", u.path, "-C", bottlesDir, selected]) }
    }

    func restoreBottle() {
        let p = NSOpenPanel()
        guard p.runModal() == .OK, let u = p.url else { return }
        var name = u.deletingPathExtension().lastPathComponent
        if bottles.contains(name) { name += "-restored" }
        // extract to a hidden temp dir, then rename the single top folder to the target name
        exec("/bin/sh", ["-c", "set -e; t=$(mktemp -d \"$1/.restore.XXXX\"); tar -xf \"$2\" -C \"$t\"; mv \"$t\"/* \"$1/$3\"; rmdir \"$t\"", "sh", bottlesDir, u.path, name])
    }

    // Steam's CEF UI renders black under Wine unless the sandbox and GPU path are off.
}
