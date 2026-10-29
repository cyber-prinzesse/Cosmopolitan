import Foundation

extension Model {
    // Wine's segv_handler on a Metal/D3DMetal worker (no TEB) re-enters forever: the window freezes, the process never exits.
    // Detect that and SIGKILL only that program's pid so the existing crash / driver-fallback path can run (Beta engines are
    // patched; Sikarugir 10.0_8 is not).
    static let faultLoopHeadline = "froze in a crash loop inside the graphics driver: stopped it"

    // Measured on a real hang (GravityMark D3D12 200k asteroids, D3DMetal 4.0b3, unpatched Wine ntdll, 37 threads) vs healthy DX12,
    // PROC_PIDTASKINFO rates per second over 10 s:
    //   hang:    faults 58,176/s  messages_sent 581,768/s  syscalls_mach 407,244/s  csw 117,513/s  cpu 104 %
    //   healthy: faults      0/s  messages_sent   2,949/s  syscalls_mach  27,167/s  csw   7,648/s  cpu 223 %
    // Rosetta's exception-server thread was idle (0 %); the faulting thread spun in the signal handler. Per-thread user/system
    // times under Rosetta read ~0 for the busy threads, so those can't be used. Sample whole-process counters every 5 s; fire when
    // every interval in a 20 s window (4 in a row) has faults ≥ 20,000/s and messages_sent ≥ 100,000/s.
    // Steam: steam.exe -applaunch exits before the game exists — keep polling faultLoopGamePid for up to 120 s after launch.
    func watchFaultLoop(pid startPid: Int32, exe: String, resolveGamePid: Bool = true) {
        guard startPid > 1 else { return }
        faultLoopTokens[exe] = UUID()
        let token = faultLoopTokens[exe]!
        let watchStart = Date()
        Task { @MainActor in
            var pid = startPid
            var haveGame = false
            var prev: (Date, UInt64, UInt64)? = nil   // wall, faults, messages_sent
            var hotStreak = 0
            while faultLoopTokens[exe] == token {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard faultLoopTokens[exe] == token else { return }
                if resolveGamePid, let g = self.faultLoopGamePid(exe) {
                    if g != pid { prev = nil; hotStreak = 0 }   // new process: fresh window
                    pid = g; haveGame = true
                }
                if kill(pid, 0) != 0 {
                    if resolveGamePid, !haveGame, Date().timeIntervalSince(watchStart) < 120 { continue }
                    faultLoopTokens[exe] = nil; return
                }
                guard let cur = procTaskCounts(pid) else { continue }
                let now = Date()
                defer { prev = (now, cur.faults, cur.messagesSent) }
                guard let p = prev else { continue }
                let dt = now.timeIntervalSince(p.0)
                guard dt >= 4.0 else { continue }   // need a real interval (clock skew / first sample)
                let faultsPerSec = Double(cur.faults &- p.1) / dt
                let msgsPerSec = Double(cur.messagesSent &- p.2) / dt
                if faultsPerSec >= 20_000, msgsPerSec >= 100_000 { hotStreak += 1 } else { hotStreak = 0 }
                guard hotStreak >= 4 else { continue }   // 4 × ~5 s ≈ 20 s of sustained storm
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
