import SwiftUI

extension Model {
    // Troubleshooting: every check is something that actually broke while bringing Steam up on this engine.
    func sh(_ cmd: String) -> String { shell(cmd) }
    // The wineserver serving a prefix holds /tmp/.wine-<uid>/server-<dev>-<inode>/lock, named after the prefix folder's device and inode.
    nonisolated func prefixServer(_ prefix: String) -> (pid: Int32, path: String)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: prefix),
              let dev = (a[.systemNumber] as? NSNumber)?.uint64Value, let ino = (a[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        let lock = String(format: "/tmp/.wine-%u/server-%llx-%llx/lock", getuid(), dev, ino)
        guard FileManager.default.fileExists(atPath: lock), let pid = Int32(shell("lsof -t '\(lock)' 2>/dev/null | head -1")) else { return nil }
        var path = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE; not `ps`: it's setuid, and a sandboxed process may not exec it
        return (pid, proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : "")
    }
    func regSection(_ file: String, _ key: String) -> String {
        let reg = (try? String(contentsOfFile: "\(bottlesDir)/\(selected)/\(file)", encoding: .utf8)) ?? ""
        for k in [key, key.replacingOccurrences(of: "CurrentControlSet", with: "ControlSet001")] {
            if let s = reg.components(separatedBy: "[\(k.replacingOccurrences(of: "\\", with: "\\\\"))]").dropFirst().first?.components(separatedBy: "\n[").first, !s.isEmpty { return s }
        }
        return ""
    }
    func troubleshoot() {
        var out = "── Troubleshooting ──\n"
        func check(_ ok: Bool, _ what: String, _ fix: String = "") { out += (ok ? "✓ " : "✗ ") + what + (ok || fix.isEmpty ? "" : "  →  \(fix)") + "\n" }
        let engine = ((wineBin as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent   // wswine.bundle
        let v = sh("'\(wineBin)' --version 2>&1")
        check(v.hasPrefix("wine-"), "Wine engine runs (\(v.prefix(40)))", "engine folder damaged; re-copy the Sikarugir engine")
        let icd = launchEnv(selected)["VK_DRIVER_FILES"] ?? ""
        let lib = sh("sed -n 's/.*\"library_path\" *: *\"\\([^\"]*\\)\".*/\\1/p' '\(icd)'")
        check(FileManager.default.fileExists(atPath: lib.hasPrefix("/") ? lib : (icd as NSString).deletingLastPathComponent + "/" + lib), "MoltenVK ICD present (Vulkan for DXVK)", "MoltenVK_icd.json must point at libMVK.dylib")
        let unix = engine + "/lib/wine/x86_64-unix"
        let sdl = sh("ls '\(unix)' | grep -c '^libSDL3'")
        check(FileManager.default.fileExists(atPath: unix + "/libSDL2-2.0.0.dylib") && sdl != "0", "SDL2 + SDL3 beside the engine (controllers)", "copy libSDL3*.dylib next to libSDL2-2.0.0.dylib")
        let gstMissing = sh("cd '\(unix)' && otool -L winegstreamer.so winedmo.so | awk '/@rpath/{print $1}' | sed 's|@rpath/||' | while read x; do [ -e \"$x\" ] || echo \"$x\"; done | wc -l | tr -d ' '")
        check(gstMissing == "0" && FileManager.default.fileExists(atPath: support + "/engines/gstreamer/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"), "Video/audio codecs (GStreamer) reachable — cutscenes and store videos", "Update… re-links GStreamer from the Sikarugir template")
        for d in driverList(launchEnvRaw(), bottle: selected) {
            check(FileManager.default.fileExists(atPath: "\(driversDir)/\(d)/wine"), "Driver \(d) installed", "drop the renderer folder into engines/renderer")
        }
        if !selected.isEmpty {
            check(regSection("system.reg", "System\\CurrentControlSet\\Services\\winebus").contains("\"DisableHidraw\"=dword:00000001"), "DualSense via SDL (winebus DisableHidraw=1)", "Repair")
            let dpi = regSection("user.reg", "Control Panel\\Desktop")
            check(!dpi.contains("\"LogPixels\"") || dpi.contains("\"LogPixels\"=dword:00000060"), "Bottle DPI is 96 (window sizes)", "Repair")
            let steam = FileManager.default.fileExists(atPath: "\(bottlesDir)/\(selected)/drive_c/Program Files (x86)/Steam/steam.exe")
            if steam {
                check(regSection("user.reg", "Software\\Wine\\AppDefaults\\steam.exe\\DllOverrides").contains("\"xinput1_4\"=\"\""), "Steam Input can't grab the controller (steam.exe xinput disabled)", "Repair")
                check(regSection("user.reg", "Software\\Wine\\AppDefaults\\steamwebhelper.exe\\DllOverrides").contains("\"dxgi\"=\"builtin\""), "steamwebhelper uses builtin dxgi (no crash)", "Repair")
            }
        }
        // Only this bottle's server matters: other bottles and other Wine builds running their own prefixes are normal.
        if !selected.isEmpty {
            if let s = prefixServer("\(bottlesDir)/\(selected)") {
                check(realPath(s.path).hasPrefix(realPath(engine) + "/"), "This bottle's Wine server is Cosmopolitan's engine (pid \(s.pid))", "another Wine build is running this bottle; quit it, or Repair (stops only this bottle)")
            } else { out += "• This bottle's Wine server isn't running\n" }
        }
        check(!nativeControllers().isEmpty, "Game controller connected and turned on", "press PS/Xbox button or pair it in Bluetooth settings; Wine only sees it once macOS does")
        let free = sh("df -g \"$HOME\" | awk 'NR==2{print $4}'")
        check((Int(free) ?? 0) > 10, "Disk space (\(free) GB free)", "free up space; Steam downloads fail silently when full")
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        for (s, hint) in Model.logSigns where log.contains(s) { out += "! log contains \"\(s)\": \(hint)\n" }
        out += "──\n"
        logToFile(out); self.log += out
    }
}
