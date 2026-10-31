import Foundation

extension Model {
    // Wine processes a bottle kept from a session whose wineserver is gone. A leftover driver host (winedevice.exe) keeps the
    // controllers it opened: SDL's hidapi opens pads exclusively on macOS, so the next session sees the DualSense "connected"
    // with no input (2026-10-31: a winedevice from 16:40, before a forced restart, held the pad; the game at 20:33 got nothing).
    // Stale = started before the bottle's current wineserver, or older than 30 s while the bottle has no wineserver at all (a new
    // session's first process briefly runs before its server). Only processes whose executable is one of Cosmopolitan's engine
    // loaders count, so nothing else that happens to work inside the bottle folder can be hit.
    nonisolated static var staleMinAge: TimeInterval {   // test builds: COSMO_TEST_STALE_MIN_AGE seconds
        isTestBuild ? Double(ProcessInfo.processInfo.environment["COSMO_TEST_STALE_MIN_AGE"] ?? "") ?? 30 : 30
    }
    nonisolated static func staleWineProcesses(_ bottle: String) -> [Int32] {
        let pfx = realPath("\(bottlesDir)/\(bottle)")
        let server = prefixServer(pfx)
        let serverAge = server.map { processAge($0.pid) } ?? 0
        let engines = realPath(support + "/engines") + "/"
        return procFind(".exe", under: pfx).filter { pid in
            guard pid != server?.pid else { return false }
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, realPath(String(cString: path)).hasPrefix(engines) else { return false }
            let age = processAge(pid)
            return server != nil ? age > serverAge + 1 : age > staleMinAge
        }
    }
    @discardableResult nonisolated static func endStaleWine(_ bottle: String) -> String {
        let pids = staleWineProcesses(bottle)
        guard !pids.isEmpty else { return "" }
        for pid in pids { kill(pid, SIGKILL) }
        return "Ended \(pids.count) Wine process\(pids.count == 1 ? "" : "es") left from an earlier \(bottle) session (they can keep a controller locked).\n"
    }

    // XInput DLLs a bottle lost from system32/syswow64 (seen 2026-10-31: xinput1_1/1_2/1_3 gone from the Steam bottle's system32):
    // a game importing one fails with "not found" and never sees a pad. Put back the engine's own builtin copy; present files and
    // a game's native copy in its own folder are left alone.
    nonisolated static func restoreXInputDLLs(_ bottle: String, engine: String) -> String {
        let fm = FileManager.default, win = "\(bottlesDir)/\(bottle)/drive_c/windows"
        var restored: [String] = []
        for (arch, dir) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] where fm.fileExists(atPath: "\(win)/\(dir)") {
            for d in ["xinput1_1", "xinput1_2", "xinput1_3", "xinput1_4", "xinput9_1_0", "xinputuap"] {
                let dst = "\(win)/\(dir)/\(d).dll", src = "\(engine)/lib/wine/\(arch)/\(d).dll"
                guard !fm.fileExists(atPath: dst), fm.fileExists(atPath: src), (try? fm.copyItem(atPath: src, toPath: dst)) != nil else { continue }
                restored.append("\(dir)/\(d).dll")
            }
        }
        return restored.isEmpty ? "" : "Restored missing controller DLLs in \(bottle): \(restored.joined(separator: ", ")).\n"
    }
}
