import SwiftUI

// Not a failure: Steam exits with 42 once it has applied a client update and started its new copy ("Update complete, launching Steam..."
// in its bootstrap log). No crash record, and above all no driver fallback, which would move Steam to another driver for good.
func restartExit(_ exe: String, _ code: Int32) -> Bool { code == 42 && exe.lowercased().hasSuffix("/steam/steam.exe") }

extension Model {
    func exec(_ path: String, _ args: [String], env: [String: String] = [:], block: Bool = true, exe: String? = nil, then: (@MainActor () -> Void)? = nil) {
        if block { busy = true }
        log += "$ \((path as NSString).lastPathComponent) \(args.joined(separator: " "))\n"
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
            let failed = code != 0 && !(exe.map { restartExit($0, code) } ?? false)
            self.log += code == 0 ? "[done]\n" : failed ? "[failed: exit \(code)]\n" : "[exit \(code): restarting itself after an update]\n"
            if let exe { self.launchExits[exe] = code; if failed { self.captureCrash(exe, code) } }   // item 34: a crash record for the bug report
            // Died right away: within 30 s, one retry with the next driver (item 27); otherwise look for a known cause.
            if let exe, failed, Date().timeIntervalSince(started) < 60, !(Date().timeIntervalSince(started) < 30 && self.driverFallback(exe, code)) { self.triage(exe, code) }
            then?(); self.refresh() } }
        do { try p.run() } catch { log += "Failed: \(error)\n"; busy = false }
    }

    func wine(_ bottle: String, _ args: [String], block: Bool = true, env: [String: String] = [:], drivers: [String]? = nil, exe: String? = nil, then: (@MainActor () -> Void)? = nil) {
        guard engineOK else { log += "Wine engine missing.\n"; return }
        exec(exe.map(loaderNamed) ?? wineBin, args, env: launchEnv(bottle, drivers: drivers).merging(env) { $1 }, block: block, exe: exe, then: then)
    }
}
