import SwiftUI
import Sparkle

nonisolated(unsafe) var cliExitCode: Int32 = 0   // a CLI mode can set its own exit code (--launch --wait: the program's, or 124)
let updater = SPUStandardUpdaterController(startingUpdater: !isTestBuild, updaterDelegate: nil, userDriverDelegate: nil)

@main struct CosmopolitanApp: App {
    // Terminal use: Cosmopolitan.app/Contents/MacOS/Cosmopolitan --troubleshoot [bottle] | --repair [bottle]  (same code as the buttons)
    init() {
        enterTestModeIfNeeded()   // first, before any path is computed
        let a = CommandLine.arguments
        let modes = ["--settings", "--setup", "--session-end", "--troubleshoot", "--repair", "--input", "--find", "--status", "--check", "--update", "--launch", "--tune", "--tunesteam", "--newbottle", "--accept-d3dmetal", "--snapshot", "--rollback", "--importables", "--import", "--willitrun", "--bugreport", "--hints", "--offline", "--compress", "--shaders", "--volumes", "--offlineexe", "--uslayout", "--hudocr", "--saves", "--mods", "--addmod", "--mod", "--rumble", "--padmode", "--procs", "--clean-driver-copies", "--sweep-registry", "--tree-hash", "--install-d3dmetal", "--print-env", "--install-runtime", "--snapshots", "--pad-connected", "--sync-launchers", "--bisect", "--cleanup", "--gog-signin", "--gog-redirect", "--steam-busy", "--steam-restart", "--highball-report", "--awacy-refresh", "--ludusavi-refresh", "--save-paths", "--backup-saves", "--check-updates", "--bugreport-text", "--health", "--health-fix", "--cleanup-suggestions", "--prepare-engine"]   // --launch <bottle> <exe> [seconds] | --wait [max seconds]   // --check <bottle> <exe>: dry-run of the launch check
        guard let i = a.firstIndex(where: { modes.contains($0) }) else { _ = logFile; return }   // the window app's fresh log begins at its start, not at its first write
        cliMode = true
        let m = Model()
        if i + 1 < a.count, FileManager.default.fileExists(atPath: "\(bottlesDir)/\(a[i + 1])/drive_c") { m.selected = a[i + 1]; m.scan() }   // only real bottles: caches must never create one
        // A path given here may spell a file differently from the scan (/private/tmp vs /tmp: NSHomeDirectory drops /private), and the
        // scan keys Steam games, store games and readiness by its own spelling: --launch and --check map the path onto it by real path.
        switch a[i] {
        case "--repair": m.repair(); case "--input": m.inputCheck(); case "--find": m.findApps(); case "--update": m.log += Model.performUpdate(install: a.contains("--install"))
        case "--tunesteam": m.tuneSteam()
        case "--newbottle": if i + 1 < a.count {   // --newbottle <name>: returns when the bottle is ready (at most 300 s)
            var done = false; let t0 = Date(); m.createBottle(a[i + 1]) { done = true }
            while !done, Date().timeIntervalSince(t0) < 300 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
            m.log += "newbottle: \(a[i + 1]) \(done ? "ready" : "not ready") after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n"
        }
        case "--accept-d3dmetal": m.acceptD3DMetal()   // same action as the "I accept" button; for the user's own scripting only
        case "--snapshot": m.snapshot(a.count > i + 2 ? a[i + 2] : "manual")
        case "--willitrun": if i + 2 < a.count { m.log += m.willItRun(a[i + 2]) }
        case "--bugreport": m.copyBugReport(); m.log += NSPasteboard.general.string(forType: .string)?.components(separatedBy: "\n").prefix(6).joined(separator: "\n") ?? ""; m.log += "\n"
        case "--hints": m.log += m.powerHints().isEmpty ? "no power/thermal hints right now\n" : m.powerHints()
        case "--offline": m.offlineCheck()
        case "--shaders": m.shaderCacheReport()
        case "--hudocr": if i + 2 < a.count { m.log += "fps read from image: \(Model.hudFPS(in: a[i + 2]).map { String($0) } ?? "none")\n" }
        case "--saves": if i + 2 < a.count { m.log += "save folders: \(m.saveFolders(a[i + 2]))\n" }
        case "--mods": if i + 2 < a.count { m.log += "\(m.mods(a[i + 2]))\n" }
        case "--addmod": if i + 3 < a.count { m.addMod(a[i + 2], from: a[i + 3]) }
        case "--mod": if i + 4 < a.count { m.setMod(a[i + 2], a[i + 3], enabled: a[i + 4] == "on") }
        case "--rumble": m.testRumble(); RunLoop.main.run(until: Date().addingTimeInterval(2))
        case "--settings":   // what the app decides from each setting, through the same code that uses it
            print("engine setting      → wine used: \(wineBin)  (installed: \(engineOK))")
            print("autostartSteam      → autostart allowed: \(m.autostartAllowed())")
            print("compatReports       → long session offers a report: \(Model.shouldOfferReport(enabled: UserDefaults.standard.bool(forKey: "compatReports"), seconds: 600, alreadyOffered: false))")
        case "--clean-driver-copies": let r = Model.cleanDriverCopies(m.selected); m.log += r.isEmpty ? "\(m.selected): no driver copies in system32/syswow64.\n" : "\(m.selected): moved \(r.count) driver copies:\n" + r.map { "  " + $0 }.joined(separator: "\n") + "\n"
        case "--sweep-registry": let r = m.sweepRegistry(m.selected); m.log += r.isEmpty ? "\(m.selected): no registry settings to remove.\n" : "\(m.selected): removed \(r.count) registry settings:\n" + r.map { "  " + $0 }.joined(separator: "\n") + "\n"
        case "--tree-hash": for p in a.dropFirst(i + 1) { m.log += "\(treeHash(p) ?? "unreadable")  \(p)\n" }
        case "--install-d3dmetal": if i + 1 < a.count { m.installD3DMetal(from: a[i + 1], confirmed: a.contains("--yes")) }
        case "--print-env": for (k, v) in launchEnv(m.selected).sorted(by: { $0.key < $1.key }) { m.log += "\(k)=\(v)\n" }
        case "--install-runtime": if i + 2 < a.count, let r = Runtime(rawValue: a[i + 2]) { Model.installRuntime(r, prefix: "\(bottlesDir)/\(m.selected)") { m.log += $0 } } else { m.log += "usage: --install-runtime <bottle> vcredist86|vcredist64|directx\n" }
        case "--setup": let ok = Model.performSetup(engine: engineName) { s, p in print(String(format: "[%3.0f%%] ", p * 100) + s) }; print(ok ? "setup ok" : "setup failed"); if !ok { exit(1) }
        case "--session-end": if i + 2 < a.count {   // test the report offer: --session-end <exe> <seconds> [on|off]; prints, never opens anything
            if i + 3 < a.count { UserDefaults.standard.set(a[i + 3] == "on", forKey: "compatReports") }
            let r = m.sessionEnded(a[i + 1], seconds: Double(a[i + 2]) ?? 0, ask: { print("ASK: " + $0); return true }, open: { print("WOULD OPEN (browser form, unsubmitted): " + $0.absoluteString.prefix(140)) })
            print("RESULT: " + r) }
        case "--procs": if i + 2 < a.count { m.log += "pids containing \"\(a[i + 2])\": \(procFind(a[i + 2]))  steamRunning: \(m.steamRunning())  controllers: \(nativeControllers())  battery: \(onBattery())\n" }
        case "--padmode": if i + 2 < a.count { let changed = m.ensureControllerMode(for: a[i + 2]); m.log += "changed: \(changed); hidraw disabled now: \(m.hidrawDisabled())\n" }
        case "--uslayout":   // test: switch to US for 3 s, then restore
            let before = Model.currentLayoutID(); m.log += "before: \(before)\n"
            m.log += "select US: \(Model.selectLayout("com.apple.keylayout.US")) → now \(Model.currentLayoutID())\n"
            Thread.sleep(forTimeInterval: 3); Model.selectLayout(before); m.log += "restored: \(Model.currentLayoutID())\n"
        case "--volumes": m.log += (m.externalVolumes().isEmpty ? "no writable external volumes" : m.externalVolumes().joined(separator: "\n")) + "\n"
        case "--offlineexe": if i + 2 < a.count { m.log += (m.offlineExe(a[i + 2]) ?? "no offline launcher found") + "\n" }
        case "--compress": if i + 2 < a.count { m.compressGame(a[i + 2]); RunLoop.main.run(until: Date().addingTimeInterval(120)) }
        case "--rollback":   // --rollback <bottle> [stamp]: the newest snapshot unless a stamp is given; returns when the rollback is done
            if let s = m.snapshots().first(where: { a.count <= i + 2 || $0.when == a[i + 2] }) {
                m.rollback(to: s.path); let t0 = Date(); repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) } while m.busy && Date().timeIntervalSince(t0) < 60
            } else { m.log += "no snapshots\n" }
        case "--cleanup": m.log += cleanUp(bottles: m.bottles)   // what the daily housekeeping does
        case "--gog-signin": if i + 1 < a.count { m.log += Model.gogSignIn(redirectURL: a[i + 1]).message + "\n" }   // what the sheet does with the address
        case "--gog-redirect": if i + 1 < a.count { m.log += (URL(string: a[i + 1]).map(Model.isGogRedirect) == true ? "caught" : "not a sign-in address") + "\n" }
        case "--steam-busy": m.log += "steam in \(m.selected): \(m.steamRunning() ? "running" : "not running"); \(Model.steamBusy(m.selected).map { "busy: " + $0 } ?? "idle")\n"
        case "--steam-restart": if i + 2 < a.count {   // --steam-restart <bottle> <why> [seconds to keep waiting, default 10]
            m.requestSteamRestart(a[i + 2]); RunLoop.main.run(until: Date().addingTimeInterval(Double(a.count > i + 3 ? a[i + 3] : "10") ?? 10))
            m.log += "pending restart: \(m.pendingSteamRestart.map { "yes (\($0.busy))" } ?? "no")\n"
        }
        case "--highball-report": if i + 2 < a.count { m.log += (m.reportURL(a[i + 2]).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value } ?? "no report") + "\n" }   // the prefilled text, nothing opened
        case "--awacy-refresh": m.log += Model.refreshAwacy(force: true) + "\n"
        case "--ludusavi-refresh": m.log += Model.refreshLudusavi(force: true) + "\n"
        case "--save-paths": if i + 2 < a.count { let e = m.programs.first { realPath($0) == realPath(a[i + 2]) } ?? a[i + 2]; m.log += (m.saveGame(e).map { "save game: \($0.name)\n" } ?? "save game: none\n") + m.savePaths(e).map { "save path: \($0)\n" }.joined() }
        case "--backup-saves": if i + 2 < a.count { let e = m.programs.first { realPath($0) == realPath(a[i + 2]) } ?? a[i + 2]; if m.backupSaves(e, a.count > i + 3 ? a[i + 3] : "manual").isEmpty { m.log += "no saves found\n" } }
        case "--check-updates": m.backupBeforeUpdates()   // what the minute timer does
        case "--pad-connected": m.controllerConnected("test pad")   // what a GCControllerDidConnect notification does
        case "--bugreport-text": m.log += m.bugReportText(for: i + 2 < a.count ? (m.programs.first { realPath($0) == realPath(a[i + 2]) } ?? a[i + 2]) : nil)   // the clipboard untouched
        case "--health", "--health-fix":   // the start-up health check; --health-fix also applies the fixes (a graphics component only with a yes)
            var progs: [String: Set<String>] = [:]
            for b in m.bottles where FileManager.default.fileExists(atPath: "\(bottlesDir)/\(b)/drive_c") { progs[b] = Set(m.programsIn(b).map { ($0 as NSString).lastPathComponent.lowercased() }) }
            m.healthProblems = Model.healthCheck(progs)
            if a[i] == "--health-fix" { m.fixHealth(); RunLoop.main.run(until: Date().addingTimeInterval(90)); m.healthProblems = Model.healthCheck(progs) }
            m.log += m.healthProblems.isEmpty ? "health: no problems\n" : m.healthProblems.map { "health: \($0.kind) \($0.target): \($0.text)\n" }.joined()
        case "--cleanup-suggestions":   // the list; with --apply --yes it also deletes them (the app asks instead)
            let s = Model.cleanupSuggestions(m.bottles)
            m.log += s.map { "could go: \($0.bytes) \($0.what) — \($0.path)\n" }.joined()
            if a.contains("--apply") { if a.contains("--yes") { m.applyCleanup(s) } else { m.log += "nothing deleted: --apply needs --yes\n" } }
        case "--prepare-engine": if i + 1 < a.count { m.log += Model.prepareEngine(a[i + 1]) }   // a freshly unpacked engine folder (bin/, lib/wine/)
        case "--sync-launchers": m.log += Model.writeLaunchers(m.library.map { (appName($0), nil) }, app: Bundle.main.bundlePath)   // what the app does after a scan
        case "--snapshots": for s in m.snapshots() { m.log += "snapshot \(s.when)  \(s.reason)\n" }; m.log += "disk held only by snapshots: \(Model.snapshotDiskUse(m.selected)) bytes\n"
        case "--bisect": if i + 2 < a.count { m.bisect(m.programs.first { realPath($0) == realPath(a[i + 2]) } ?? a[i + 2]); RunLoop.main.run(until: Date().addingTimeInterval(3)) }
        case "--importables": m.log += m.importableBottles().map { "\($0.label)\t\($0.path)" }.joined(separator: "\n") + "\n"
        case "--import": if i + 3 < a.count { m.importBottle(a[i + 2], as: a[i + 3]); RunLoop.main.run(until: Date().addingTimeInterval(60)) }
        case "--tune": if i + 2 < a.count { m.log += m.tuneUnreal(a[i + 2]) ?? "nothing to tune (no settings file yet, or already tuned)\n" }
        case "--launch": if i + 2 < a.count {
            let exe = m.programs.first { realPath($0) == realPath(a[i + 2]) } ?? a[i + 2], name = (exe as NSString).lastPathComponent   // the scan's spelling
            if let w = a.firstIndex(of: "--wait") {   // --launch <bottle> <exe> --wait [max seconds, default 120]: until the program exits
                let limit = Double(a.count > w + 1 ? a[w + 1] : "120") ?? 120, t0 = Date()
                m.launchOutputToLog = true
                m.launch(exe)
                while m.launchExits[exe] == nil, !m.log.contains("\(name) is already running."), Date().timeIntervalSince(t0) < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
                let took = String(format: "%.1f", Date().timeIntervalSince(t0))
                if let code = m.launchExits[exe] { m.log += "launch: \(name) exited with code \(code) after \(took) s\n"; cliExitCode = code }
                else if m.log.contains("\(name) is already running.") { m.log += "launch: \(name) was already running; not started again\n"; cliExitCode = 124 }
                else { m.log += "launch: \(name) still running after \(took) s (limit \(Int(limit)) s); left running\n"; cliExitCode = 124 }
            } else {   // the old behaviour: run for a fixed time (default 30 s), then end with the CLI
                m.launch(exe); RunLoop.main.run(until: Date().addingTimeInterval(Double(a.count > i + 3 ? a[i + 3] : "30") ?? 30))
            }
        }
        case "--check": if i + 2 < a.count { let n = m.launchNeeds(m.programs.first { realPath($0) == realPath(a[i + 2]) } ?? a[i + 2]); m.log += n.note + "drivers override: \(n.drivers ?? ["(bottle setting)"]) verbs: \(n.verbs) overrides: \(n.overrides) env: \(n.env) args: \(n.args) desktop: \(n.desktop) light: \(n.status == .green ? "green" : n.status == .yellow ? "yellow" : "red")\n" }
        case "--status": m.log += "d3dmetal: " + (m.d3dmetalNow.map { "\($0.pretty) from \($0.source); features: " + $0.features.sorted().joined(separator: " ") + (d3dmetalOK ? "; license accepted" : "; license not accepted") } ?? "not installed") + "\n"; m.log += "drivers: \(m.driverStatus.0 == .green ? "green" : m.driverStatus.0 == .yellow ? "yellow" : "red") (\(m.driverStatus.1))\ncontroller: \(m.padStatus.0 == .green ? "green" : m.padStatus.0 == .yellow ? "yellow" : "red") (\(m.padStatus.1))\nbattery summary: \(m.batterySummary())\nbattery profile: \(powerReason() ?? "off")\n"; m.log += "library: \(m.library.count) games, \(m.library.count - Set(m.library).count) listed twice\n"
        default: m.troubleshoot() }
        print(m.log); exit(cliExitCode)
    }
    var body: some Scene {
        WindowGroup("Cosmopolitan") { ContentView().handlesExternalEvents(preferring: ["launch"], allowing: ["*"]) }   // cosmopolitan://launch?name=<program> goes to the existing window, not a new one (§7.7 via Shortcuts/Siri)
            .commands { CommandGroup(after: .appInfo) { Button("Check for Updates…") { updater.checkForUpdates(nil) } } }
            .windowStyle(.hiddenTitleBar)   // the frost runs up to the window's top edge, behind the traffic lights
        Settings { SettingsView() }
    }
}
