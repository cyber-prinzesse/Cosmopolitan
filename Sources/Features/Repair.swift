import SwiftUI

extension Model {
    // Safe, idempotent fixes for the ✗ lines above.
    func repair() {
        guard !selected.isEmpty else { return }
        let r = "\(bottlesDir)/\(selected)"
        guard let lock = PrefixLock(r, purpose: "repair") else { log += "Repair: another repair is already running on \(selected) (\(PrefixLock.holder(r))).\n"; return }
        defer { withExtendedLifetime(lock) {} }   // held until Repair returns; released by the kernel if the app dies
        busy = true
        snapshot("before Repair"); backupBottleSaves(selected, "before Repair")   // item 30: saves too, kept apart from snapshots
        log += "Repair: stopping this bottle's Wine processes…\n"
        // wineserver -k/-w act on $WINEPREFIX's server only; without WINEPREFIX they'd target ~/.wine. Other bottles, other Wine builds
        // and Mac processes are never touched (this used to pkill every ".exe" command line and every wineserver on the Mac).
        let ws = "env WINEPREFIX=\(shq("\(r)")) \(shq("\((wineBin as NSString).deletingLastPathComponent)/wineserver"))"
        _ = sh("\(ws) -k; \(ws) -w; true")
        let cmds = [["reg", "add", "HKLM\\System\\CurrentControlSet\\Services\\winebus", "/v", "DisableHidraw", "/t", "REG_DWORD", "/d", "1", "/f"],
                    ["reg", "add", "HKCU\\Control Panel\\Desktop", "/v", "LogPixels", "/t", "REG_DWORD", "/d", "96", "/f"],
                    ["reg", "add", "HKCU\\Software\\Wine\\Fonts", "/v", "LogPixels", "/t", "REG_DWORD", "/d", "96", "/f"]]
        let env = launchEnv(selected).map { "\($0.key)=\(shq("\($0.value)"))" }.joined(separator: " ")
        for c in cmds { _ = sh("env \(env) \(shq("\(wineBin)")) " + c.map { "\(shq("\($0)"))" }.joined(separator: " ") + " >/dev/null 2>&1") }
        if FileManager.default.fileExists(atPath: r + "/drive_c/Program Files (x86)/Steam/steam.exe") { steamBottleTweaks() }   // recorded in the ledger
        // Test build only: hold the lock with this bottle's wineserver (started by the reg commands) alive, so tests can kill the app here.
        if isTestBuild, let s = Double(ProcessInfo.processInfo.environment["COSMO_TEST_HOLD_LOCK_SECS"] ?? "") {
            _ = sh("env \(env) \(shq("\(wineBin)")) cmd /c ping -n \(Int(s) + 30) 127.0.0.1 >/dev/null 2>&1 &")   // a Wine child that outlives the app
            Thread.sleep(forTimeInterval: s)
        }
        if !FileManager.default.fileExists(atPath: Model.dotnetMarker(r)) { Model.ensureDotNet(r) { self.log += $0 } }
        let moved = Model.cleanDriverCopies(selected)   // driver DLLs that ended up in system32/syswow64 (exact-hash copies only)
        if !moved.isEmpty { log += "Moved \(moved.count) driver copies out of the system folders:\n" + moved.map { "  " + $0 }.joined(separator: "\n") + "\n" }
        _ = sh("\(ws) -w")   // wait for the server to exit = registry flushed to disk
        busy = false
        log += "Repair done. Run Troubleshoot again to confirm, then relaunch your program.\n"
        scan()
    }
}
