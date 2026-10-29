import Foundation

extension Model {
    // Wine's segv_handler on a Metal/D3DMetal worker (no TEB) re-enters forever: the window freezes, the process never exits, and
    // Rosetta's "com.apple.rosetta.exceptionserver" thread sits at ~100 % of a core (normally ~0). Detect that and SIGKILL only that
    // program's pid so the existing crash / driver-fallback path can run (Beta engines are patched; Sikarugir 10.0_8 is not).
    static let faultLoopHeadline = "froze in a crash loop inside the graphics driver: stopped it"

    // Sample every 5 s; fire when that thread used ≥ 40 % of wall over a full 20 s window. Idle is ~0; a SIGSEGV stand-in under
    // Rosetta splits ~50/50 with the JIT thread; a real D3DMetal hang puts the exception server alone near 100 %. 40 % catches both
    // without flagging a busy non-faulting x86 process (exception server stays at ~0).
    func watchFaultLoop(pid startPid: Int32, exe: String, resolveGamePid: Bool = true) {
        guard startPid > 1 else { return }
        faultLoopTokens[exe] = UUID()
        let token = faultLoopTokens[exe]!
        Task { @MainActor in
            var samples: [(Date, Int64)] = []
            var pid = startPid
            while faultLoopTokens[exe] == token {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard faultLoopTokens[exe] == token else { return }
                if resolveGamePid, let g = self.faultLoopGamePid(exe), g != pid { pid = g }   // Steam starts the game as a child
                if kill(pid, 0) != 0 { faultLoopTokens[exe] = nil; return }   // already gone
                guard let cpu = rosettaExcCPUNs(pid) else { continue }   // no Rosetta thread yet / native: stay cheap, keep waiting
                let now = Date()
                samples.append((now, cpu))
                samples.removeAll { now.timeIntervalSince($0.0) > 25 }
                guard let first = samples.first, now.timeIntervalSince(first.0) >= 20 else { continue }
                let wall = now.timeIntervalSince(first.0)
                let used = Double(cpu - first.1) / 1_000_000_000.0 / wall
                guard used >= 0.40 else { continue }
                let name = appName(exe)
                log += "\(name) \(Model.faultLoopHeadline)\n"
                faultLoopCrash[exe] = true
                faultLoopTokens[exe] = nil
                kill(pid, SIGKILL)   // this pid only — never wineserver or other bottles
                // CLI --faultloop has no Process terminationHandler: write the crash record and offer a driver fallback here.
                if ProcessInfo.processInfo.arguments.contains("--faultloop") {
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

    // Test CLI: --faultloop <pid> [max seconds] — runs the same detector against an arbitrary pid (stand-in under Rosetta).
    func faultLoopCLI(pid: Int32, limit: TimeInterval) {
        // Under Games/ so appName → "FaultLoopStandin" (drive_c/...exe alone would name the crash record "drive_c").
        let exe = "\(bottlesDir)/\(selected)/drive_c/Games/FaultLoopStandin/FaultLoopStandin.exe"
        let t0 = Date()
        watchFaultLoop(pid: pid, exe: exe, resolveGamePid: false)
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
