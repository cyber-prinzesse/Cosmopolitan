import CoreGraphics
import Foundation

extension Model {
    // Steam's CEF UI (software-composited under Wine) burns CPU while the window is up. When Steam is hidden or a game is
    // running, move this bottle's steamwebhelper processes into Darwin background QoS (PRIO_DARWIN_BG); restore when the
    // window is shown again and no game is running. Opt out with STEAM_IDLE_DIET=0 on steam.exe's options or the bottle's
    // cosmopolitan.env. Never touches another bottle or Mac Steam.app.
    nonisolated static func steamExePath(_ bottle: String) -> String {
        "\(bottlesDir)/\(bottle)/drive_c/Program Files (x86)/Steam/steam.exe"
    }

    // STEAM_IDLE_DIET=0 opts out (program options win over bottle env).
    func steamIdleDietEnabled(in bottle: String) -> Bool {
        let steam = Model.steamExePath(bottle)
        if options(steam)["STEAM_IDLE_DIET"] == "0" { return false }
        if launchEnvRaw(bottle)["STEAM_IDLE_DIET"] == "0" { return false }
        return true
    }

    // steamwebhelper PIDs whose Wine cwd is inside this bottle (never another bottle / Mac Steam).
    nonisolated static func steamWebhelperPids(in bottle: String) -> [Int32] {
        guard !bottle.isEmpty else { return [] }
        let under = realPath("\(bottlesDir)/\(bottle)")
        return procFind("steamwebhelper.exe", under: under)
    }

    // On-screen layer-0 windows owned by this bottle's Steam / webhelper pids. Test: COSMO_TEST_STEAM_VISIBLE=0|1.
    func steamWindowVisible(in bottle: String) -> Bool {
        if isTestBuild, let v = ProcessInfo.processInfo.environment["COSMO_TEST_STEAM_VISIBLE"] {
            return v == "1" || v.lowercased() == "true" || v.lowercased() == "yes"
        }
        let under = realPath("\(bottlesDir)/\(bottle)")
        var owners = Set(Model.steamWebhelperPids(in: bottle))
        for p in procFind("Steam\\steam.exe", under: under) { owners.insert(p) }
        for p in procFind("steam.exe", under: under) { owners.insert(p) }
        guard !owners.isEmpty else { return false }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let wins = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in wins {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, owners.contains(pid) else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let wd = (b["Width"] as? CGFloat) ?? 0, ht = (b["Height"] as? CGFloat) ?? 0
            if layer == 0, wd > 50, ht > 50 { return true }
        }
        return false
    }

    // Throttle when enabled and (a game is running in this bottle, or Steam's window is not on screen).
    func steamIdleDietShouldThrottle(in bottle: String) -> Bool {
        guard steamIdleDietEnabled(in: bottle), steamRunning(in: bottle) else { return false }
        if Model.steamBusy(bottle) == "a game is running" { return true }
        return !steamWindowVisible(in: bottle)
    }

    // Apply or clear Darwin BG on this bottle's webhelper pids only. Returns the pids now in BG.
    @discardableResult
    func steamIdleDietTick(bottle: String? = nil, forceLog: Bool = false) -> [Int32] {
        warnMacSteamIfNeeded()
        let bottles = bottle.map { [$0] } ?? self.bottles
        var last: [Int32] = []
        for b in bottles where !b.isEmpty {
            last = steamIdleDietTickOne(b, forceLog: forceLog)
        }
        return last
    }

    private func steamIdleDietTickOne(_ bottle: String, forceLog: Bool) -> [Int32] {
        let want = steamIdleDietShouldThrottle(in: bottle)
        let live = Set(Model.steamWebhelperPids(in: bottle))
        var applied = steamIdleDietApplied[bottle] ?? []
        // Drop dead pids from the bookkeeping set.
        applied = applied.intersection(live)

        if !want {
            for pid in applied { Model.setDarwinBackground(pid, enabled: false) }
            if !applied.isEmpty {
                let m = "Steam idle diet: restored normal priority for \(bottle) (\(applied.count) webhelper process\(applied.count == 1 ? "" : "es")).\n"
                log += m; if forceLog || steamIdleDietLogged.contains(bottle + ":off") == false { logToFile(m); steamIdleDietLogged.insert(bottle + ":off") }
            }
            steamIdleDietApplied[bottle] = []
            return []
        }

        guard steamIdleDietEnabled(in: bottle) else {
            for pid in applied { Model.setDarwinBackground(pid, enabled: false) }
            steamIdleDietApplied[bottle] = []
            return []
        }

        // Only spawn taskpolicy for pids not already tracked (Steam respawns helpers). Do not re-assert every 5 s —
        // each call launches /usr/sbin/taskpolicy (a full process), not a cheap syscall.
        // Skip helpers still starting: before the window exists Steam counts as "hidden", and Darwin BG (CPU + disk I/O throttle)
        // on a booting webhelper stretched a cold start to 105 s / 17 min until Steam's watchdog said "steamwebhelper is not
        // responding" (2026-10-31). Young pids are picked up by a later 5 s tick.
        let toAdd = live.subtracting(applied).filter { Model.processAge($0) >= Model.steamIdleDietMinAge }
        for pid in toAdd { Model.setDarwinBackground(pid, enabled: true) }
        applied = applied.union(toAdd).intersection(live)
        steamIdleDietApplied[bottle] = applied
        if !applied.isEmpty, forceLog || !steamIdleDietLogged.contains(bottle + ":on") {
            let why = Model.steamBusy(bottle) == "a game is running" ? "a game is running" : "Steam's window is hidden"
            let m = "Steam idle diet: background QoS for \(bottle)'s webhelper (\(applied.count) process\(applied.count == 1 ? "" : "es"); \(why)). STEAM_IDLE_DIET=0 opts out.\n"
            log += m; logToFile(m); steamIdleDietLogged.insert(bottle + ":on")
        }
        return Array(applied).sorted()
    }

    // ponytail: fixed 120 s grace; tie it to "Steam's window seen once" if a slow Mac still trips the watchdog.
    // Test builds: COSMO_TEST_DIET_MIN_AGE overrides (stand-ins are fresh).
    nonisolated static var steamIdleDietMinAge: TimeInterval {
        if isTestBuild, let v = ProcessInfo.processInfo.environment["COSMO_TEST_DIET_MIN_AGE"], let s = TimeInterval(v) { return s }
        return 120
    }

    // Seconds since pid started; 0 when unknown (treated as young, so never throttled by mistake).
    nonisolated static func processAge(_ pid: Int32) -> TimeInterval {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return Date().timeIntervalSince1970 - (TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    // taskpolicy -b/-B (not setpriority alone): on macOS 26, setpriority(PRIO_DARWIN_PROCESS, pid, 1) succeeds
    // but does not move the target into Darwin BG; /usr/sbin/taskpolicy -b -p does (measured under CPU oversubscription).
    // Call only on throttle on/off or a newly seen pid — each invocation launches a process.
    nonisolated static func setDarwinBackground(_ pid: Int32, enabled: Bool) {
        guard pid > 1 else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        p.arguments = [enabled ? "-b" : "-B", "-p", String(pid)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    // Mac Steam.app running alongside a bottle Steam: one warning (never signal it).
    func warnMacSteamIfNeeded() {
        guard !macSteamWarned else { return }
        let mac = procFind("/Applications/Steam.app/")
        guard !mac.isEmpty else { return }
        // Only warn when a Cosmo bottle also has Steam up.
        guard bottles.contains(where: { steamRunning(in: $0) }) else { return }
        macSteamWarned = true
        let m = "⚠ Mac Steam is running alongside a Cosmopolitan Steam bottle (pids \(mac.map(String.init).joined(separator: ", "))). Cosmopolitan only manages the bottle's Steam; quit Mac Steam if they fight over accounts or downloads.\n"
        log += m; logToFile(m)
    }

    // CLI / tests: one tick; prints diet state for the selected bottle.
    func steamIdleDietCLI() {
        let b = selected
        let pids = steamIdleDietTick(bottle: b, forceLog: true)
        let en = steamIdleDietEnabled(in: b)
        let vis = steamWindowVisible(in: b)
        let busy = Model.steamBusy(b) ?? "idle"
        let live = Model.steamWebhelperPids(in: b)
        log += "steam-idle: bottle=\(b) enabled=\(en ? "yes" : "no") visible=\(vis ? "yes" : "no") busy=\(busy) webhelpers=\(live.map(String.init).joined(separator: ",")) throttled=\(pids.map(String.init).joined(separator: ","))\n"
    }
}
