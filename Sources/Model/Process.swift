import SwiftUI

// Not a failure: Steam exits with 42 once it has applied a client update and started its new copy ("Update complete, launching Steam..."
// in its bootstrap log). No crash record. driverFallback also refuses steam.exe for any other early exit — a DXVK pin on Steam
// would leave every Steam Play game without D3DMetal ("Support for DirectX 12 is missing").
func restartExit(_ exe: String, _ code: Int32) -> Bool { code == 42 && exe.lowercased().hasSuffix("/steam/steam.exe") }

extension Model {
    func exec(_ path: String, _ args: [String], env: [String: String] = [:], block: Bool = true, exe: String? = nil, then: (@MainActor () -> Void)? = nil) {
        if block { busy = true }
        // Log the Dock/host name (Steam, …), not cosmo_wineloader — that is the dispatcher file Cosmo exec's.
        let shown = (path as NSString).lastPathComponent == Model.wineloaderName
            ? (exe.map { Model.loaderProcessName(for: $0) } ?? "wine")
            : (path as NSString).lastPathComponent
        log += "$ \(shown) \(args.joined(separator: " "))\n"
        let started = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        if let exe, FileManager.default.fileExists(atPath: exe) { p.currentDirectoryURL = URL(fileURLWithPath: (exe as NSString).deletingLastPathComponent) }   // like Explorer: a program starts in its own folder

        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        // CLI --wait: a pipe's reader dies with the CLI and the program's later output is lost (Wine ignores SIGPIPE, so the program
        // itself keeps running); the log file outlives the CLI and keeps that output.
        let logFD = launchOutputToLog && exe != nil ? open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644) : -1   // O_APPEND: the app appends to it too
        if logFD >= 0 { let fh = FileHandle(fileDescriptor: logFD, closeOnDealloc: true); p.standardOutput = fh; p.standardError = fh }
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if !s.isEmpty { logToFile(s); Task { @MainActor in self.log += s } }
        }
        p.terminationHandler = { t in let code = t.terminationStatus; Task { @MainActor in
            pipe.fileHandleForReading.readabilityHandler = nil
            if block { self.busy = false }
            // Steam -applaunch exits before the game exists; the fault-loop watch keeps polling for the game pid (up to 120 s).
            if let exe, steamGames[exe] == nil { self.stopFaultLoopWatch(exe) }
            let failed = code != 0 && !(exe.map { restartExit($0, code) } ?? false)
            self.log += code == 0 ? "[done]\n" : failed ? "[failed: exit \(code)]\n" : "[exit \(code): restarting itself after an update]\n"
            if let exe {
                self.launchExits[exe] = code
                if failed {
                    // Fault-loop kill: same crash path as a normal exit, with a headline that names the freeze (and the driver-fallback offer).
                    let head = self.faultLoopCrash.removeValue(forKey: exe) == true ? "\(appName(exe)) \(Model.faultLoopHeadline)" : nil
                    self.captureCrash(exe, code, headline: head)
                } else { self.faultLoopCrash[exe] = nil }
            }
            // Died right away: within 30 s, one retry with the next driver (item 27); otherwise look for a known cause.
            if let exe, failed, Date().timeIntervalSince(started) < 60, !(Date().timeIntervalSince(started) < 30 && self.driverFallback(exe, code)) { self.triage(exe, code) }
            then?(); self.refresh() } }
        do {
            try p.run()
            // Rosetta fault-loop watch: sample the exception-server thread while this program (or its Wine child) runs.
            if let exe { watchFaultLoop(pid: p.processIdentifier, exe: exe) }
        } catch { log += "Failed: \(error)\n"; busy = false; then?() }   // still run then (e.g. PreparingWindow.end) on launch failure
    }

    func wine(_ bottle: String, _ args: [String], block: Bool = true, env: [String: String] = [:], drivers: [String]? = nil, exe: String? = nil, then: (@MainActor () -> Void)? = nil) {
        guard engineOK else { log += "Wine engine missing.\n"; Task { @MainActor in then?() }; return }
        let loader = exe.map(loaderNamed) ?? wineBin
        var e = launchEnv(bottle, drivers: drivers, fullSpeed: env["FULL_SPEED"] == "1").merging(env) { $1 }
        // Children CreateProcess through WINELOADER; keep it on the dispatcher so each exe can get its own Dock file name.
        if (loader as NSString).lastPathComponent == Model.wineloaderName {
            e["WINELOADER"] = loader
            if let exe { e["COSMO_LOADER_NAME"] = Model.loaderProcessName(for: exe) }
        }
        // Cosmos: the first program's Dock name. Its children get their own from the registry (syncDockAppNames), never this one.
        if let exe, engineHasDockPatches() { e["WINEMACAPPNAME"] = Model.loaderProcessName(for: exe) }
        exec(loader, args, env: e, block: block, exe: exe, then: then)
    }
}
