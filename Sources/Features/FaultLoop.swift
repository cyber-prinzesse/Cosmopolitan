import Foundation

extension Model {
    // Wine's segv_handler on a Metal/D3DMetal worker (no TEB) re-enters forever: the window freezes, the process never exits, and
    // Rosetta's "com.apple.rosetta.exceptionserver" thread burns a core (normally ~0). Detect that and SIGKILL only that program's
    // pid so the existing crash / driver-fallback path can run (Beta engines are patched; Sikarugir 10.0_8 is not).
    static let faultLoopHeadline = "froze in a crash loop inside the graphics driver: stopped it"

    // Sample every 5 s over a 20 s window. Fire when the exception server used ≥ 40 % of a core and ≥ 50 % of the whole process's
    // CPU (PROC_PIDTASKINFO pti_total_*): in a real hang it is nearly alone (write-watch storms with busy game threads stay ~10 %).
    // A 2-thread Rosetta infinite-fault stand-in shares the storm with the JIT peer (~47 %); that peer is not game work, so the
    // half-process bar is also met when there are only those two threads and the 40 %-of-a-core floor holds.
    // Steam: steam.exe -applaunch exits before the game exists — keep polling faultLoopGamePid for up to 120 s after launch.
    func watchFaultLoop(pid startPid: Int32, exe: String, resolveGamePid: Bool = true) {
        guard startPid > 1 else { return }
        faultLoopTokens[exe] = UUID()
        let token = faultLoopTokens[exe]!
        let watchStart = Date()
        Task { @MainActor in
            var samples: [(Date, Int64, Int64)] = []   // wall, exception-server ns, process ns
            var pid = startPid
            var haveGame = false
            while faultLoopTokens[exe] == token {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard faultLoopTokens[exe] == token else { return }
                if resolveGamePid, let g = self.faultLoopGamePid(exe) {
                    if g != pid { samples.removeAll() }   // new process: fresh window
                    pid = g; haveGame = true
                }
                if kill(pid, 0) != 0 {
                    // Launcher gone before the game appeared: keep looking until the 120 s handoff window ends.
                    if resolveGamePid, !haveGame, Date().timeIntervalSince(watchStart) < 120 { continue }
                    faultLoopTokens[exe] = nil; return
                }
                guard let exc = rosettaExcCPUNs(pid), let proc = procCPUNs(pid) else { continue }   // no Rosetta thread / native: stay cheap
                let now = Date()
                samples.append((now, exc, proc))
                samples.removeAll { now.timeIntervalSince($0.0) > 25 }
                guard let first = samples.first, now.timeIntervalSince(first.0) >= 20 else { continue }
                let wall = now.timeIntervalSince(first.0)
                let excDelta = exc - first.1, procDelta = proc - first.2
                guard procDelta > 0 else { continue }
                let ofCore = Double(excDelta) / 1_000_000_000.0 / wall
                let ofProc = Double(excDelta) / Double(procDelta)
                let alone = ofProc >= 0.50 || (procThreadCount(pid) <= 2 && ofCore >= 0.40)
                guard ofCore >= 0.40, alone else { continue }
                let name = appName(exe)
                log += "\(name) \(Model.faultLoopHeadline)\n"
                faultLoopCrash[exe] = true
                faultLoopTokens[exe] = nil
                kill(pid, SIGKILL)   // this pid only — never wineserver or other bottles
                // Steam -applaunch: our Process already exited successfully, so the crash path must run here. CLI --faultloop too.
                if self.launchExits[exe] != nil || ProcessInfo.processInfo.arguments.contains("--faultloop") {
                    launchExits[exe] = 9
                    captureCrash(exe, 9, headline: "\(name) \(Model.faultLoopHeadline)")
                    _ = driverFallback(exe, 9)
                }
                return
            }
        }
    }

    // The Windows program's Unix pid when Wine put it in its own process; else nil (same process as the loader we started).
    func faultLoopGamePid(_ exe: String) -> Int32? {
        let under = realPath("\(bottlesDir)/\(bottleOf(exe))")
        let hits = procFind(winPath(exe), under: under)
        return hits.first ?? procFind((exe as NSString).lastPathComponent, under: under).first
    }

    func stopFaultLoopWatch(_ exe: String) { faultLoopTokens[exe] = nil }

    // Test CLI: --faultloop <pid> [max seconds] — same detector; resolveGamePid finds a child named like the stand-in under the bottle.
    func faultLoopCLI(pid: Int32, limit: TimeInterval) {
        // Under Games/ so appName → "FaultLoopStandin" (drive_c/...exe alone would name the crash record "drive_c").
        let exe = "\(bottlesDir)/\(selected)/drive_c/Games/FaultLoopStandin/FaultLoopStandin.exe"
        let t0 = Date()
        watchFaultLoop(pid: pid, exe: exe, resolveGamePid: true)
        while faultLoopTokens[exe] != nil, Date().timeIntervalSince(t0) < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        if faultLoopTokens[exe] != nil {
            stopFaultLoopWatch(exe)
            log += "faultloop: pid \(pid) still running after \(Int(limit)) s (not flagged)\n"
            cliExitCode = 124
        } else if faultLoopCrash[exe] == true {
            log += "faultloop: detected and stopped pid \(pid) after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n"
            cliExitCode = 0
        } else {
            log += "faultloop: pid \(pid) exited on its own before a fault loop was seen\n"
            cliExitCode = 1
        }
    }
}
