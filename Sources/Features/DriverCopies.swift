import Foundation

// Driver DLLs belong in the bottle's drivers/ links, loaded per launch, never in system32/syswow64. Two things used to put them there:
// creating a bottle (wineboot ran with the driver slots active) and Wine's own automatic prefix update after an engine change (same).

// Wine updates a prefix by itself when <prefix>/.update-timestamp differs from wine.inf's mtime, inside whatever launch hit it. Doing it
// first, without driver slots, keeps that update from copying driver DLLs into the prefix.
// The last part of the Windows command Wine writes into a process's argv[0] (C:\…\steam.exe → steam.exe), read like procFind reads it.
private func programName(_ pid: Int32) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "?" }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return "?" }
    let fields = buf[4..<size].split(separator: 0)   // argc, then the exec path, then argv[0]…
    guard fields.count > 1, let a0 = String(bytes: fields[1], encoding: .utf8) else { return "?" }
    return a0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? a0
}
nonisolated(unsafe) private var updateTimedOut: Set<String> = []   // prefixes whose update ran out of time in this run
private let updateLock = NSLock()
func updatePrefixIfStale(_ prefix: String) {
    let file = prefix + "/.update-timestamp", raw = try? String(contentsOfFile: file, encoding: .utf8)
    let stamp = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let inf = (wineBin as NSString).deletingLastPathComponent + "/../share/wine/wine.inf"
    guard FileManager.default.fileExists(atPath: prefix + "/drive_c"), stamp != "disable",
          let m = (try? FileManager.default.attributesOfItem(atPath: inf))?[.modificationDate] as? Date, stamp != String(Int(m.timeIntervalSince1970)) else { return }
    // Every Wine command builds a launch environment, so after a timeout this would start (and wait for) another update at once; once per run.
    updateLock.lock(); let tried = updateTimedOut.contains(prefix); updateLock.unlock()
    if tried { return }
    // Mono and Gecko stay out of the update, as in createBottle: Cosmopolitan installs and checks Wine Mono itself, and a newer engine's
    // wineboot otherwise wants its own newer Wine Mono and waits on that download (Wine 11 with Mono 9.4.0 in the bottle: for good).
    let limit = (isTestBuild ? Int(ProcessInfo.processInfo.environment["COSMO_TEST_UPDATE_TIMEOUT"] ?? "") : nil) ?? 300
    let name = (prefix as NSString).lastPathComponent
    PreparingWindow.begin(bottle: name)   // GUI: Cosmos preparing window while wineboot -u runs (Wine 10 still shows its own underneath)
    defer { PreparingWindow.end() }
    let wb = Process(); wb.executableURL = URL(fileURLWithPath: "/bin/sh")
    wb.arguments = ["-c", "exec env WINEDLLOVERRIDES='mscoree,mshtml=' \(plainWine(prefix)) wineboot -u >/dev/null 2>&1"]
    guard (try? wb.run()) != nil else { return }
    let deadline = Date().addingTimeInterval(Double(limit))
    while wb.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    guard wb.isRunning else { return }   // finished in time
    updateLock.lock(); updateTimedOut.insert(prefix); updateLock.unlock()   // tried again at the next start, not by the next command
    // Wine writes the new stamp when the update starts: the old one goes back, so the next start tries again.
    if let raw { try? raw.write(toFile: file, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(atPath: file) }
    // Nothing is stopped at the limit itself: stopping only the update's wineboot/rundll32 leaves this session's boot unfinished, and Wine
    // makes every new program in the session wait for it (tested: about 300 s, then it gives up). So: nothing but Wine's own processes in
    // this prefix → the update, its leftovers and the wineserver go (nothing of yours lost; the launch gets a clean session). Anything else
    // running there (Steam, a game) → nothing is touched; the update finishes in the background and programs start once it has. The update
    // runs winemenubuilder.exe and iexplore.exe itself (wine.inf RunServices, RegisterDlls): counted as yours, they kept a stuck update
    // running with nothing else there. Programs are told apart by working folder (inside the bottle, as every launch sets it).
    let dir = realPath(prefix), own = ["services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "explorer.exe",
                                       "conhost.exe", "start.exe", "rundll32.exe", "wineboot.exe", "winemenubuilder.exe", "iexplore.exe"]
    let ownPids = Set(own.flatMap { procFind($0, under: dir) }), others = procFind(".exe", under: dir).filter { !ownPids.contains($0) }
    if others.isEmpty {
        kill(wb.processIdentifier, SIGKILL)
        for n in ["rundll32.exe", "wineboot.exe"] { for p in procFind(n, under: dir) { kill(p, SIGKILL) } }
        _ = shell("env WINEPREFIX='\(prefix)' '\((wineBin as NSString).deletingLastPathComponent)/wineserver' -k 2>/dev/null")
        logToFile("Updating \(name) for this engine didn't finish in \(limit) s; it was stopped (nothing else was running there) and will be tried again at the next start.\n")
    } else {
        let what = Set(others.map(programName)).sorted().joined(separator: ", ")
        logToFile("Updating \(name) for this engine didn't finish in \(limit) s; left running because \(others.count) other program\(others.count == 1 ? "" : "s") run there (\(what)); it will be tried again at the next start if it doesn't finish.\n")
    }
}

extension Model {
    // Moves out of system32/syswow64 only the files whose SHA-256 equals a DLL from one of our backend folders (current, *.old, d3dmetal@*),
    // restores Wine's own copy from the engine, and returns what was moved. Moved files go to support/_to_delete/<date>/<bottle>/.
    nonisolated static func cleanDriverCopies(_ bottle: String) -> [String] {
        let fm = FileManager.default, win = "\(bottlesDir)/\(bottle)/drive_c/windows", lib = (wineBin as NSString).deletingLastPathComponent + "/../lib/wine"
        var ours: [String: String] = [:]   // sha256 → "backend/arch/file"
        for d in (try? fm.contentsOfDirectory(atPath: driversDir)) ?? [] where !d.hasPrefix(".") {
            for arch in ["x86_64-windows", "i386-windows"] {
                for f in (try? fm.contentsOfDirectory(atPath: "\(driversDir)/\(d)/wine/\(arch)")) ?? [] where f.lowercased().hasSuffix(".dll") {
                    if let h = sha256File("\(driversDir)/\(d)/wine/\(arch)/\(f)") { ours[h] = "\(d)/\(arch)/\(f)" }
                }
            }
        }
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f.string(from: Date()) }()
        var moved: [String] = []
        for (sys, arch) in [("system32", "x86_64-windows"), ("syswow64", "i386-windows")] {
            for f in (try? fm.contentsOfDirectory(atPath: "\(win)/\(sys)")) ?? [] where f.lowercased().hasSuffix(".dll") {
                let p = "\(win)/\(sys)/\(f)"
                guard let h = sha256File(p), let from = ours[h] else { continue }
                let dst = "\(support)/_to_delete/\(stamp)/\(bottle)/\(sys)"
                try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
                guard (try? fm.moveItem(atPath: p, toPath: "\(dst)/\(f)")) != nil else { continue }
                let own = "\(lib)/\(arch)/\(f)"
                if fm.fileExists(atPath: own) { try? fm.copyItem(atPath: own, toPath: p) }
                moved.append("\(sys)/\(f) (copy of \(from)) → \(dst)/\(f)" + (fm.fileExists(atPath: p) ? "; Wine's own restored" : ""))
            }
        }
        return moved
    }
}
