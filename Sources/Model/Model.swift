import SwiftUI
import Network

@MainActor final class Model: ObservableObject {
    @Published var bottles: [String] = []
    @Published var selected = ""
    @Published var programs: [String] = []
    @Published var log = engineOK ? "" : "Wine engine not found at \(wineBin)\n"
    @Published var busy = false
    var launchExits: [String: Int32] = [:]   // exit code of each program started with exe: (the CLI's --launch --wait polls this)
    var launchOutputToLog = false            // CLI --wait: program output goes to the log file, not a pipe, so it survives the CLI exiting
    var icons: [String: NSImage] = [:]
    @Published var hud = false       // MTL_HUD_ENABLED (Metal performance overlay)
    @Published var retina = false    // Wine Mac Driver RetinaMode
    @Published var drivers: Set<String> = []   // enabled renderer folders (DRIVERS= in cosmopolitan.env)
    @Published var autoDrivers = true          // DRIVERS absent or "auto"
    @Published var driverStatus: (Color, String) = (.gray, "")   // traffic light + one-line reason
    @Published var padStatus: (Color, String) = (.gray, "")
    var loading = false
    // green = will work, yellow = will work with a caveat / nothing to test right now, red = broken until fixed.
    func updateStatus() {
        guard !selected.isEmpty else { driverStatus = (.gray, "no bottle"); padStatus = (.gray, "no bottle"); return }
        let list = driverList(launchEnvRaw(), bottle: selected), fm = FileManager.default
        let missing = list.filter { !fm.fileExists(atPath: "\(driversDir)/\($0)/wine") }
        let d3d11 = list.filter { ["dxmt", "dxvk", "dxvk3", "d3dmetal"].contains($0) }
        let icdFile = launchEnv(selected)["VK_DRIVER_FILES"] ?? ""
        let icdLib = ((try? String(contentsOfFile: icdFile, encoding: .utf8)) ?? "").components(separatedBy: "\"library_path\":\"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
        let icd = fm.fileExists(atPath: icdLib)   // the json must exist AND point at a real libMVK.dylib
        if !engineOK { driverStatus = (.red, "Wine engine missing") }
        else if !missing.isEmpty { driverStatus = (.red, "missing: " + missing.joined(separator: ", ")) }
        else if !icd { driverStatus = (.red, "MoltenVK ICD missing (no Vulkan)") }
        else if d3d11.count > 1 { driverStatus = (.yellow, "conflict: " + d3d11.joined(separator: " + ") + " — keep one") }
        else if d3d11.isEmpty { driverStatus = (.yellow, "no Direct3D 10/11 driver enabled") }
        else { driverStatus = (.green, list.joined(separator: " + ")) }
        let bus = regSection("system.reg", "System\\CurrentControlSet\\Services\\winebus")
        let pads = nativeControllers().joined(separator: ", ")   // IOKit HID, no shell
        if !bus.contains("\"DisableHidraw\"=dword:00000001") || bus.contains("\"Enable SDL\"=dword:00000000") { padStatus = (.red, "bottle not set for SDL pads → Repair") }
        else if pads.isEmpty { padStatus = (.yellow, "bottle ready, no controller switched on") }
        else { padStatus = (.green, pads) }
    }
    func setDriver(_ d: String, _ on: Bool) {
        if on { drivers.insert(d) } else { drivers.remove(d) }
        autoDrivers = false
        envSet("DRIVERS", drivers.sorted().joined(separator: ","))   // "DRIVERS=" (empty) means none, unlike absent = auto
        updateStatus()
    }
    func setAuto(_ on: Bool) {
        autoDrivers = on
        if on { drivers = Set(autoDriverSet); envSet("DRIVERS", nil) } else { envSet("DRIVERS", drivers.sorted().joined(separator: ",")) }
        updateStatus()
    }
    @Published var template = "auto"
    // "auto": new bottles are win10; each old program gets its own Windows version (win98 / winxp) from its exe header at launch.
    let templates = ["auto", "win11", "win10", "win7", "winxp", "win98", "win95"]
    @Published var driverUpdates = ""   // "dxmt v0.81 available" — filled by the weekly check, applied by Update…
    @Published var readiness: [String: Needs] = [:]   // per-program pre-verification (tile light + tooltip)
    var lastMemWarn = Date.distantPast                 // memory advisor rate limit
    @Published var pendingSteamRestart: (bottle: String, why: String, busy: String)? = nil   // a Steam restart waiting for idle (item 24)
    var steamWaitArmed = false
    @Published var library: [String] = []                         // every bottle's games, for the Library (item 39)
    @Published var online = true                                  // the Library says per game whether it starts without internet
    @Published var problem: (game: String, text: String)? = nil  // a problem in plain words, shown with a Fix button
    @Published var settingUp: Set<String> = []                    // games whose first start is installing what they need
    @Published var askD3DMetal = false                            // Fix this game: Apple's toolkit is the user's step, its sheet opens
    @Published var activity = ""                                  // one plain sentence about what is happening (no raw log in the Library)
    let pathMonitor = NWPathMonitor()
    var launchedDrivers: [String: [String]] = [:]                // the driver set each program last started with (driver fallback)
    var fallbackTried: Set<String> = []                           // programs on their one fallback retry
    @Published var healthProblems: [HealthProblem] = []           // found by the start-up health check (item 35)
    @Published var artVersion = 0                      // bumped when cover art or playtime files change, so tiles redraw
    var pauseObservers: [NSObjectProtocol] = []        // pause-in-background observers, one per armed game
    @Published var showSetup = false           // first-run setup sheet
    @Published var setupRunning = false
    @Published var setupProgress = 0.0
    @Published var setupStep = ""
    var engineReady: Bool { engineOK }
    @Published var autostartSteam = false              // AUTOSTART_STEAM=1 in cosmopolitan.env: Steam comes up with the app, with the bottle's drivers
    @Published var batterySaver = false   // 60 fps cap in D3DMetal and DXMT, DXMT renders at 2/3 and MetalFX-upscales: far less GPU work on battery
    @Published var metalFX = false        // D3DM_ENABLE_METALFX: a game's DLSS menu option becomes MetalFX temporal upscaling (D3DMetal, macOS 26+)
    func setBatterySaver(_ on: Bool) {
        envSet("D3DM_MAX_FPS", on ? "60" : nil)
        envSet("DXMT_CONFIG", on ? "d3d11.preferredMaxFrameRate=60;d3d11.metalSpatialUpscaleFactor=1.5" : nil)
    }
    // Steam of one bottle (default: the selected one). Wine keeps each process's working folder on its Windows current directory, so this
    // bottle's Steam, and every game it starts, works inside the bottle; another bottle's Steam doesn't count. libproc, no ps.
    func steamRunning(in bottle: String? = nil) -> Bool { Model.steamRunning(bottle ?? selected) }
    nonisolated static func steamRunning(_ bottle: String) -> Bool { !bottle.isEmpty && !procFind("Steam\\steam.exe", under: realPath("\(bottlesDir)/\(bottle)")).isEmpty }
    // Stop this bottle's Steam: ask politely; if it is still up after 20 s (it sometimes ignores -shutdown), stop this bottle's Wine programs
    // (its own wineserver). Never another bottle's Steam: this used to pkill every steam.exe on the Mac.
    func stopSteam(_ bottle: String? = nil) async {
        let b = bottle ?? selected, pfx = "\(bottlesDir)/\(b)", ws = "\((wineBin as NSString).deletingLastPathComponent)/wineserver"
        wine(b, ["C:\\Program Files (x86)\\Steam\\steam.exe", "-shutdown"], block: false)
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000_000); if !steamRunning(in: b) { break } }
        if steamRunning(in: b) { log += "Steam ignored the shutdown request; stopping \(b)'s programs.\n"; _ = sh("env WINEPREFIX='\(pfx)' '\(ws)' -k") }
        // Let the prefix's wineserver finish tearing down (≤15 s); relaunching into a dying server made Steam fail to create its first window.
        _ = sh("env WINEPREFIX='\(pfx)' perl -e 'alarm 15; exec @ARGV' -- '\(ws)' -w 2>/dev/null; sleep 1")
    }
    // Item 24: why this bottle's Steam must not be restarted right now, or nil. A download: an app manifest in a download/update state, or
    // Steam's own Updating flag. A game: a process from steamapps\common working inside this bottle, or Steam's Running flag.
    nonisolated static func steamBusy(_ bottle: String) -> String? {
        let pfx = "\(bottlesDir)/\(bottle)", apps = pfx + "/drive_c/Program Files (x86)/Steam/steamapps"
        if !procFind("steamapps\\common", under: realPath(pfx)).isEmpty { return "a game is running" }
        let active = 256 | 1024 | 131072 | 262144 | 524288 | 1048576 | 2097152 | 4194304   // EAppState: update running/started, validating,
        func field(_ t: String, _ k: String) -> String? {                                     // adding files, preallocating, downloading, staging, committing
            t.range(of: "\"\(k)\"\\s+\"[^\"]*\"", options: .regularExpression).map { String(t[$0]).components(separatedBy: "\"").dropLast().last ?? "" }
        }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? [] where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
            let t = (try? String(contentsOfFile: "\(apps)/\(f)", encoding: .utf8)) ?? ""
            if let flags = field(t, "StateFlags").flatMap({ Int($0) }), flags & active != 0 { return "downloading \(field(t, "name") ?? f)" }
        }
        let reg = (try? String(contentsOfFile: pfx + "/user.reg", encoding: .utf8)) ?? ""
        for sec in reg.components(separatedBy: "\n[") where sec.hasPrefix("Software\\\\Valve\\\\Steam\\\\Apps\\\\") {
            if sec.contains("\"Updating\"=dword:00000001") { return "updating a game" }
            if sec.contains("\"Running\"=dword:00000001") { return "a game is running" }
        }
        return nil
    }
    // Item 24: never a surprise Steam restart. Idle: restart now. Downloading or a game running: wait (re-checked every 20 s) and say so;
    // the bar above the programs offers "Restart now" (the user's call) and "Not now" (the change reaches games at Steam's next start).
    func requestSteamRestart(_ why: String) {
        let b = selected
        guard programs.contains(where: { $0.lowercased().hasSuffix("/steam/steam.exe") }), steamRunning(in: b) else { return }
        if let busy = Model.steamBusy(b) {
            if pendingSteamRestart == nil { let m = "Steam will restart once it's idle (\(busy) now), so \(why).\n"; log += m; logToFile(m) }
            pendingSteamRestart = (b, why, busy)
            guard !steamWaitArmed else { return }
            steamWaitArmed = true
            Task { @MainActor in
                while let p = pendingSteamRestart, let now = Model.steamBusy(p.bottle) { pendingSteamRestart?.busy = now; try? await Task.sleep(nanoseconds: UInt64(steamIdlePoll * 1e9)) }
                steamWaitArmed = false
                if let p = pendingSteamRestart, p.bottle == selected { pendingSteamRestart = nil; requestSteamRestart(p.why) }
            }
            return
        }
        restartSteam(b, because: why)
    }
    func restartSteam(_ b: String, because why: String) {
        guard let s = programs.first(where: { $0.lowercased().hasSuffix("/steam/steam.exe") }) else { return }
        let m = "Restarting Steam so \(why)…\n"; log += m; logToFile(m)
        Task { @MainActor in await stopSteam(b); launch(s) }
    }
    var steamIdlePoll: Double { isTestBuild ? Double(ProcessInfo.processInfo.environment["COSMO_TEST_IDLE_POLL"] ?? "") ?? 20 : 20 }
    // Asks before something the user may not want right now. The CLI can't show a dialog: it logs the question and answers Cancel, unless
    // the test build is told otherwise (COSMO_TEST_ANSWER=yes).
    func ask(_ question: String, _ detail: String, yes: String) -> Bool {
        if cliMode { let y = isTestBuild && ProcessInfo.processInfo.environment["COSMO_TEST_ANSWER"] == "yes"; log += "ASK: \(question) \(detail) → \(y ? yes : "Cancel")\n"; return y }
        let a = NSAlert(); a.messageText = question; a.informativeText = detail; a.addButton(withTitle: yes); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
    // Settings › "Start Steam together with Cosmopolitan" (default on), and AUTOSTART_STEAM=0 in a bottle opts that bottle out.
    func autostartAllowed() -> Bool { (UserDefaults.standard.object(forKey: "autostartSteam") == nil || UserDefaults.standard.bool(forKey: "autostartSteam")) && launchEnvRaw()["AUTOSTART_STEAM"] != "0" }
    func autostart() {   // a bottle with Steam gets Steam started with the app (AUTOSTART_STEAM=0 in cosmopolitan.env opts out)
        guard !cliMode, autostartAllowed(), let s = programs.first(where: { $0.lowercased().hasSuffix("/steam/steam.exe") }) else { return }
        launch(s)   // launch() skips it when Steam is already running
    }
    var watchers: [DispatchSourceFileSystemObject] = [], watchedBottle = "", rescanWork: DispatchWorkItem?
    // Watch the bottle's program folders: a finished Steam install or an installer's output shows up without clicking anything.
    func watchBottle() {
        watchers.forEach { $0.cancel() }; watchers = []; watchedBottle = selected
        guard !selected.isEmpty else { return }
        let c = "\(bottlesDir)/\(selected)/drive_c"
        for d in ["\(c)/Games/Epic", "\(c)/GOG Games"] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }   // store targets exist so they can be watched
        for dir in ["\(c)/Program Files (x86)/Steam/steamapps", "\(c)/Program Files", "\(c)/Program Files (x86)", "\(c)/Games/Epic", "\(c)/GOG Games"] {
            let fd = open(dir, O_EVTONLY); guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                rescanWork?.cancel()
                let w = DispatchWorkItem { Task { @MainActor in self.scan() } }; rescanWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)   // debounce: Steam and the store clients touch these folders constantly while running
            }
            src.setCancelHandler { close(fd) }
            src.resume(); watchers.append(src)
        }
    }

    init() {
        refresh()
        checkDriverUpdates()
        if !cliMode { dailyCleanUp(); watchNetwork(); Task.detached(priority: .background) { _ = Model.refreshAwacy(); _ = Model.refreshLudusavi() }   // lists, daily / weekly
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.backupBeforeUpdates() } }   // saves before a Steam update
            runHealthCheck()   // item 35
            watchControllers()   // item 33
            if setupNeeded && UserDefaults.standard.bool(forKey: "onboardingDone") { showSetup = true } }
        autostart()
        // Pad on/off and driver folders change outside the app; re-check every 5 s while the app is active (avoids background IOHIDManager polls while a game runs).
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in guard NSApp?.isActive != false else { return }; self?.updateStatus() } }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.memoryAdvisor() } }
    }

    func refresh() {
        linkSharedBottles()
        let all = (try? FileManager.default.contentsOfDirectory(atPath: bottlesDir)) ?? []
        // Safety clones made before Repair (.auto-<bottle>-<date>) stay hidden and are dropped after 30 days.
        for b in all where b.hasPrefix(".auto-") {
            if let m = (try? FileManager.default.attributesOfItem(atPath: "\(bottlesDir)/\(b)"))?[.modificationDate] as? Date, Date().timeIntervalSince(m) > 30 * 86400 { try? FileManager.default.removeItem(atPath: "\(bottlesDir)/\(b)") }
        }
        bottles = all.filter { !$0.hasPrefix(".") }.sorted()
        if !bottles.contains(selected) { selected = bottles.first ?? "" }
        scan()
    }

    // Per-bottle settings: KEY=VALUE lines in <bottle>/cosmopolitan.env.
    var envPath: String { "\(bottlesDir)/\(selected)/cosmopolitan.env" }
    func envSet(_ key: String, _ value: String?) {
        guard !selected.isEmpty else { return }
        var lines = ((try? String(contentsOfFile: envPath, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.hasPrefix(key + "=") }
        if let v = value { lines.append("\(key)=\(v)") }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: envPath, atomically: true, encoding: .utf8)
    }

    func loadSettings() {
        loading = true
        let e = launchEnvRaw()
        hud = e["MTL_HUD_ENABLED"] == "1"
        autostartSteam = e["AUTOSTART_STEAM"] == "1"
        batterySaver = e["D3DM_MAX_FPS"] != nil
        metalFX = e["D3DM_ENABLE_METALFX"] == "1"
        autoDrivers = e["DRIVERS"] == nil || e["DRIVERS"] == "auto"
        drivers = Set(driverList(e, bottle: selected))
        let reg = (try? String(contentsOfFile: "\(bottlesDir)/\(selected)/user.reg", encoding: .utf8)) ?? ""
        let sec = reg.components(separatedBy: "[Software\\\\Wine\\\\Mac Driver]").dropFirst().first?.components(separatedBy: "\n[").first ?? ""
        retina = sec.contains("\"RetinaMode\"=\"y\"")
        loading = false
        updateStatus()
    }
    // The bottle a program lives in, from its path (<bottlesDir>/<bottle>/drive_c/…); the selected one for anything else.
    func bottleOf(_ exe: String) -> String {
        let pre = bottlesDir + "/"
        guard exe.hasPrefix(pre), let b = exe.dropFirst(pre.count).split(separator: "/").first else { return selected }
        return String(b)
    }
    func launchEnvRaw(_ bottle: String? = nil) -> [String: String] {
        var e: [String: String] = [:]
        for l in ((try? String(contentsOfFile: "\(bottlesDir)/\(bottle ?? selected)/cosmopolitan.env", encoding: .utf8)) ?? "").components(separatedBy: "\n") {
            let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { e[kv[0]] = kv[1] }
        }
        return e
    }

    // Installed programs = non-helper .exe files directly inside each app folder under Program Files.
    func scan() {
        loadSettings()
        programs = []
        guard !selected.isEmpty else { library = []; return }
        programs = programsIn(selected)
        // The Library shows every bottle's games in one grid (item 39); the launch check works per game, whatever bottle is selected.
        library = (bottles.filter { $0 != selected && FileManager.default.fileExists(atPath: "\(bottlesDir)/\($0)/drive_c") }.flatMap { programsIn($0) } + programs)
            .sorted { appName($0).lowercased() < appName($1).lowercased() }
        verifyAll(); fetchArt(); if !cliMode { syncLaunchers() }   // item 37: a Dock/Launchpad entry per game
        if watchedBottle != selected { watchBottle(); excludeFromBackups(selected) }
        for b in unpluggedBottles() { log += "Bottle \(b) is on a drive that is not connected; it reappears when the drive is plugged in.\n" }
    }

    // The programs of one bottle: store libraries, Program Files, GOG/Epic folders and "Find apps" extras, one tile per application.
    func programsIn(_ bottle: String) -> [String] {
        let c = "\(bottlesDir)/\(bottle)/drive_c"
        var found: [String] = []
        for root in ["Program Files", "Program Files (x86)"] {
            guard let apps = try? FileManager.default.contentsOfDirectory(atPath: "\(c)/\(root)") else { continue }
            for app in apps where !app.hasPrefix(".") && !["Common Files", "Internet Explorer", "Windows NT", "Windows Media Player", "Windows Defender", "Microsoft", "Wine", "WindowsApps", "GOG Galaxy"].contains(app) {   // Galaxy's Windows client stays blank under Wine on macOS; the Stores menu offers GOG's Mac client instead
                let base = "\(c)/\(root)/\(app)"
                let items = (try? FileManager.default.subpathsOfDirectory(atPath: base)) ?? []
                for i in items where i.lowercased().hasSuffix(".exe") && i.split(separator: "/").count == 1 {
                    let n = (i as NSString).lastPathComponent.lowercased()
                    if !skipExes.contains(where: { n.contains($0) }) { found.append("\(base)/\(i)") }
                }
            }
        }
        // Steam library: one entry per appmanifest, pointing at the biggest top-level exe in its install folder.
        let lib = "\(c)/Program Files (x86)/Steam/steamapps"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: lib)) ?? [] where f.hasPrefix("appmanifest_") {
            guard let acf = try? String(contentsOfFile: "\(lib)/\(f)", encoding: .utf8) else { continue }
            func val(_ k: String) -> String { acf.components(separatedBy: "\"\(k)\"").dropFirst().first?.components(separatedBy: "\"").dropFirst().first ?? "" }
            let id = val("appid"), dir = "\(lib)/common/\(val("installdir"))"
            guard id != "228980" else { continue }   // Steamworks Common Redistributables
            // Biggest real exe: top level first; Unreal games keep it in <Game>/Binaries/Win64 with nothing at the top, so fall back to a 4-deep walk.
            func exes(_ depth: Int) -> [String] {
                guard let en = FileManager.default.enumerator(atPath: dir) else { return [] }
                var out: [String] = []
                for case let p as String in en {
                    if en.level > depth || p.hasPrefix("Engine/") || p.lowercased().contains("redist") { en.skipDescendants(); continue }
                    let n = (p as NSString).lastPathComponent.lowercased()
                    if n.hasSuffix(".exe") && !skipExes.contains(where: { n.contains($0) }) { out.append(p) }
                }
                return out
            }
            var found1 = exes(2); if found1.isEmpty { found1 = exes(4) }
            // The game's own exe: name matching the game (Magicka2.exe in engine/) beats bigger extras (an interactive map, an editor).
            let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
            let game = norm(val("name")), inst = norm(val("installdir"))
            func score(_ n: String) -> Int {
                let base = norm(((n as NSString).lastPathComponent as NSString).deletingPathExtension)
                var s = min((try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(n)"))?[.size] as? Int ?? 0, 200_000_000) / 10_000_000   // 0–20 by size
                if base == game || base == inst { s += 100 } else if !base.isEmpty, game.hasPrefix(base) || base.hasPrefix(game) || inst.hasPrefix(base) || base.hasPrefix(inst) { s += 60 }
                if ["map", "editor", "tool", "config", "settings", "benchmark", "server", "sdk", "manual", "soundtrack"].contains(where: { n.lowercased().contains($0) }) { s -= 80 }
                return s
            }
            guard let exe = found1.max(by: { score($0) < score($1) }) else { continue }
            steamGames["\(dir)/\(exe)"] = (id, val("name"))
            found.append("\(dir)/\(exe)")
        }
        for p in storeGames(bottle) where !found.contains(p) { found.append(p) }   // GOG game folders, Legendary-installed Epic games
        // Extras from "Find apps" (dropped silently once uninstalled).
        for p in ((try? String(contentsOfFile: "\(bottlesDir)/\(bottle)/cosmopolitan.apps", encoding: .utf8)) ?? "").components(separatedBy: "\n")
            where !p.isEmpty && !found.contains(p) && FileManager.default.fileExists(atPath: p) { found.append(p) }
        found = dedupe(found)   // one tile per application folder
        for p in found where icons[p] == nil { icons[p] = exeIcon(p) }
        return found.sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() }
    }

    // Run any executable; `block` locks the UI buttons until it exits.
}
