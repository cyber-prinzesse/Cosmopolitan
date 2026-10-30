import SwiftUI

// Per-session: don't spam the log when Steam already has the user's own LaunchOptions for a game.
private var steamLaunchWarned: Set<String> = []
// Per-session: one-shot "Steam's Play won't skip REDlauncher until Steam restarts" while LaunchOptions are still missing.
private var steamLaunchPendingWarned: Set<String> = []

extension Model {
    func launchCmd(_ exe: String) -> (String, [String]) {
        if let g = steamGames[exe], let r = exe.range(of: "/steamapps/") {
            let steam = String(exe[..<r.lowerBound]) + "/steam.exe"
            // Args after -applaunch <id> are forwarded to the game; Steam keeps its own -cef-* on steam.exe.
            return (winPath(steam), extraArgs(steam) + ["-applaunch", g.id] + extraArgs(exe))
        }
        // Ubisoft Connect on a Wine 11 engine: its window stays blank unless Chromium draws inside upc.exe itself (in-process, in
        // software); the UbisoftConnect.exe stub doesn't pass switches on, so start upc.exe the way the stub does, plus the switches.
        if engineIsWine11(), let upc = ubisoftClient(exe) { return (winPath(upc), ["-upc_desktop_mode"] + Model.ubisoftCEFSwitches + extraArgs(exe)) }
        return (winPath(exe), extraArgs(exe))
    }

    // Item 3: measured on r29 — default start: blank window; with these: the login page (as on other Mac Wine launchers). Wine 10 stays blank either way.
    static let ubisoftCEFSwitches = ["--no-sandbox", "--in-process-gpu", "--disable-gpu"]
    func ubisoftClient(_ exe: String) -> String? {
        guard ["ubisoftconnect.exe", "upc.exe"].contains((exe as NSString).lastPathComponent.lowercased()) else { return nil }
        let upc = (exe as NSString).deletingLastPathComponent + "/upc.exe"
        return FileManager.default.fileExists(atPath: upc) ? upc : nil
    }

    // What Steam's Play should put in LaunchOptions (not Cosmopolitan's own Play — that still uses LaunchCheck's --launcher-skip).
    // CDPR: REDlauncher 5.6 draws under Wine with GLES + GPU off (REDprelauncher forwards these); no --launcher-skip / -dx12 here.
    // Other games: CEF switches + user ARGS. Not env vars — Steam can't carry those.
    func steamLaunchArgs(_ exe: String) -> [String] {
        let dir = (exe as NSString).deletingLastPathComponent
        var a: [String]
        if Model.redGame(dir) != nil {
            a = ["--launcher-used-gl=GLES", "--disable-gpu", "--disable-gpu-compositing"]
        } else {
            a = extraArgs(exe)
        }
        if let u = options(exe)["ARGS"], !u.isEmpty {
            a += u.split(separator: " ").map(String.init)
        }
        return a
    }

    // 1.3.9 wrote CDPR skip into LaunchOptions; treat those strings as Cosmopolitan's so the GLES fix can replace them.
    nonisolated static func isPriorCosmoSteamLaunchOptions(_ value: String) -> Bool {
        value == "--launcher-skip" || value == "--launcher-skip -dx11" || value == "--launcher-skip -dx12"
            || value.hasPrefix("--launcher-skip -dx11 ") || value.hasPrefix("--launcher-skip -dx12 ")
    }

    // True when every userdata account already has Cosmopolitan's desired LaunchOptions for this Steam game.
    func steamLaunchOptionsApplied(_ exe: String) -> Bool {
        guard let g = steamGames[exe] else { return true }
        let desired = steamLaunchArgs(exe).joined(separator: " ")
        if desired.isEmpty { return true }
        let bottle = bottleOf(exe), steamDir = "\(bottlesDir)/\(bottle)/drive_c/Program Files (x86)/Steam"
        let users = (try? FileManager.default.contentsOfDirectory(atPath: "\(steamDir)/userdata")) ?? []
        guard !users.isEmpty else { return true }
        return users.allSatisfy { u in
            guard let s = try? String(contentsOfFile: "\(steamDir)/userdata/\(u)/config/localconfig.vdf", encoding: .utf8) else { return false }
            return Model.vdfLaunchOptions(s, appid: g.id) == desired
        }
    }

    // Play while Steam is up and LaunchOptions aren't synced yet: say once that Steam's own Play needs a Steam restart (don't restart for them).
    func warnSteamLaunchOptionsPending(_ exe: String) {
        guard steamGames[exe] != nil, steamRunning(), !steamLaunchOptionsApplied(exe) else { return }
        let key = "\(bottleOf(exe))/\(steamGames[exe]!.id)"
        guard !steamLaunchPendingWarned.contains(key) else { return }
        steamLaunchPendingWarned.insert(key)
        let msg = "Steam's own Play button won't get Cosmopolitan's REDlauncher fix until Steam restarts; Cosmopolitan's Play works now.\n"
        logToFile(msg); log += msg
    }

    // Write Cosmopolitan's per-game args into every userdata/*/config/localconfig.vdf as LaunchOptions, so Steam's own Play button matches.
    // Only while this bottle's Steam is down (Steam rewrites the file on exit). Sidecar options/.steamlaunch-<appid> remembers our last write
    // so a later change replaces only our value; a non-empty LaunchOptions that isn't ours is left alone.
    func syncSteamLaunchOptions(for only: String? = nil, bottle: String? = nil) {
        let bottle = bottle ?? selected
        guard !bottle.isEmpty, !steamRunning(in: bottle) else { return }
        let steamDir = "\(bottlesDir)/\(bottle)/drive_c/Program Files (x86)/Steam", fm = FileManager.default
        let targets: [(exe: String, id: String, name: String)]
        if let only, let g = steamGames[only] { targets = [(only, g.id, g.name)] }
        else { targets = steamGames.compactMap { exe, g in bottleOf(exe) == bottle ? (exe, g.id, g.name) : nil } }
        guard !targets.isEmpty else { return }
        let users = (try? fm.contentsOfDirectory(atPath: "\(steamDir)/userdata")) ?? []
        for (exe, appid, name) in targets {
            let desired = steamLaunchArgs(exe).joined(separator: " ")
            let side = "\(bottlesDir)/\(bottle)/options/.steamlaunch-\(appid)"
            let last = (try? String(contentsOfFile: side, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.createDirectory(atPath: (side as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var wroteSide = false
            for u in users {
                let p = "\(steamDir)/userdata/\(u)/config/localconfig.vdf"
                guard var s = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
                let cur = Model.vdfLaunchOptions(s, appid: appid)
                // Already equals what we'd write (user typed the same string): adopt via sidecar, leave the VDF alone.
                if let cur, !desired.isEmpty, cur == desired {
                    if last != desired {
                        try? desired.write(toFile: side, atomically: true, encoding: .utf8)
                        wroteSide = true
                    }
                    continue
                }
                // Ours if it matches the sidecar, or a prior Cosmopolitan write (1.3.9 --launcher-skip …) — replace those.
                let ours = cur == last || (cur.map { Model.isPriorCosmoSteamLaunchOptions($0) } ?? false)
                // Non-empty and not ours → the user's own text; leave it.
                if let cur, !cur.isEmpty, !ours {
                    let key = "\(bottle)/\(appid)"
                    if !steamLaunchWarned.contains(key) {
                        steamLaunchWarned.insert(key)
                        let msg = "Steam has your own launch options for \(name); Cosmopolitan's (\(desired)) not applied\n"
                        logToFile(msg); log += msg
                    }
                    continue
                }
                let next: String? = desired.isEmpty ? nil : desired
                // Empty desired: remove only a value we wrote (or an empty key left from us).
                if next == nil, cur == nil || cur?.isEmpty == true {
                    if last != nil { try? fm.removeItem(atPath: side); wroteSide = true }
                    continue
                }
                if next == nil, cur != last { continue }   // shouldn't reach (handled above), belt-and-braces
                guard Model.vdfSetLaunchOptions(&s, appid: appid, value: next) else { continue }
                let bak = p + ".bak"
                if !fm.fileExists(atPath: bak) { try? fm.copyItem(atPath: p, toPath: bak) }
                try? s.write(toFile: p, atomically: true, encoding: .utf8)
                if let next {
                    try? next.write(toFile: side, atomically: true, encoding: .utf8)
                } else {
                    try? fm.removeItem(atPath: side)
                }
                wroteSide = true
            }
            if !wroteSide, desired.isEmpty, last != nil { try? fm.removeItem(atPath: side) }
        }
    }

    // Settle delay after steam.exe is gone before editing localconfig (Steam rewrites it on exit). Test: COSMO_TEST_STEAM_EXIT_DELAY seconds (default 2).
    var steamLaunchSyncDelay: Double {
        isTestBuild ? Double(ProcessInfo.processInfo.environment["COSMO_TEST_STEAM_EXIT_DELAY"] ?? "") ?? 2 : 2
    }

    // Apply LaunchOptions for every bottle whose Steam is not running (startup / already-down; no exit edge to observe).
    func syncSteamLaunchOptionsWhileSteamDown() {
        for b in bottles where !steamRunning(in: b) {
            steamSeenRunning[b] = false
            syncSteamLaunchOptions(bottle: b)
        }
    }

    // Track running → not running per bottle; after Steam exits, wait for localconfig settle then sync LaunchOptions (covers any Steam starter).
    // User quit (not Cosmopolitan's own stopSteam): cancel a pending idle-restart and bump steamRestartEpoch so an in-flight restartSteam
    // does not bring Steam back — that was Shutdown → Startup 7–10 s later with Cosmopolitan's -cef-* / -no-cef-sandbox flags.
    func noteSteamRunningState() {
        for b in bottles {
            let up = steamRunning(in: b)
            let was = steamSeenRunning[b] ?? false
            steamSeenRunning[b] = up
            if was && !up {
                if !steamStopOwned.contains(b) {
                    steamRestartEpoch[b] = (steamRestartEpoch[b] ?? 0) + 1
                    if pendingSteamRestart?.bottle == b {
                        pendingSteamRestart = nil
                        let msg = "Steam quit: cancelled a pending restart so it stays down.\n"; log += msg; logToFile(msg)
                    }
                }
                scheduleSteamLaunchSync(b)
            }
        }
    }

    // Pretend Steam was up then run the same tick as the background Steam watch (CLI/tests: --steam-exit-sync). Not gated on app active.
    func steamExitSyncNow() {
        guard !selected.isEmpty else { return }
        steamSeenRunning[selected] = true
        noteSteamRunningState()
    }

    func scheduleSteamLaunchSync(_ bottle: String) {
        let delay = steamLaunchSyncDelay
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !steamRunning(in: bottle) else { return }
            syncSteamLaunchOptions(bottle: bottle)
        }
    }
}

// MARK: - localconfig.vdf LaunchOptions (Software/Valve/Steam/Apps/<appid>)

extension Model {
    /// Current LaunchOptions string for appid, or nil if the key (or app block) is missing.
    nonisolated static func vdfLaunchOptions(_ s: String, appid: String) -> String? {
        guard let app = vdfAppsAppInterior(s, appid: appid) else { return nil }
        return vdfStringValue(s, key: "LaunchOptions", in: app)
    }

    /// Set or remove LaunchOptions inside Apps/<appid>. Creates the app block when missing. Returns whether `s` changed.
    nonisolated static func vdfSetLaunchOptions(_ s: inout String, appid: String, value: String?) -> Bool {
        guard let apps = vdfPathBlock(s, keys: ["UserLocalConfigStore", "Software", "Valve", "Steam", "Apps"]) else { return false }
        if let app = vdfChildBlock(s, key: appid, in: apps.interior) {
            // Edit a copy of the app interior so String.Index values stay valid, then splice it back.
            var interior = String(s[app.interior])
            let whole = interior.startIndex..<interior.endIndex
            let changed = value.map { vdfSetStringValue(&interior, key: "LaunchOptions", value: $0, in: whole) }
                ?? vdfRemoveStringKey(&interior, key: "LaunchOptions", in: whole)
            if changed { s.replaceSubrange(app.interior, with: interior) }
            return changed
        }
        // No app block yet: only create one when we have something to write.
        guard let value else { return false }
        let indent = vdfChildIndent(s, in: apps.interior) ?? String(repeating: "\t", count: 5)
        let inner = indent + "\t"
        let block = "\(indent)\"\(appid)\"\n\(indent){\n\(inner)\"LaunchOptions\"\t\t\"\(vdfEscape(value))\"\n\(indent)}\n"
        s.insert(contentsOf: block, at: apps.interior.lowerBound)
        return true
    }

    // Interior range of Apps/<appid>, or nil.
    nonisolated private static func vdfAppsAppInterior(_ s: String, appid: String) -> Range<String.Index>? {
        guard let apps = vdfPathBlock(s, keys: ["UserLocalConfigStore", "Software", "Valve", "Steam", "Apps"]),
              let app = vdfChildBlock(s, key: appid, in: apps.interior) else { return nil }
        return app.interior
    }

    nonisolated private static func vdfPathBlock(_ s: String, keys: [String]) -> (interior: Range<String.Index>, full: Range<String.Index>)? {
        var scope = s.startIndex..<s.endIndex
        var last: (interior: Range<String.Index>, full: Range<String.Index>)?
        for k in keys {
            guard let b = vdfChildBlock(s, key: k, in: scope) else { return nil }
            last = b; scope = b.interior
        }
        return last
    }

    /// First subsection `"key" { ... }` inside `range` (case-insensitive key).
    nonisolated private static func vdfChildBlock(_ s: String, key: String, in range: Range<String.Index>) -> (interior: Range<String.Index>, full: Range<String.Index>)? {
        guard let kr = vdfFindKey(s, key: key, in: range) else { return nil }
        var i = kr.upperBound
        while i < range.upperBound, s[i].isWhitespace { i = s.index(after: i) }
        guard i < range.upperBound, s[i] == "{" , let close = vdfMatchingBrace(s, open: i) else { return nil }
        let interior = s.index(after: i)..<close
        return (interior, kr.lowerBound..<s.index(after: close))
    }

    nonisolated private static func vdfFindKey(_ s: String, key: String, in range: Range<String.Index>) -> Range<String.Index>? {
        let want = key.lowercased()
        var i = range.lowerBound
        while i < range.upperBound {
            if s[i] == "\"" {
                let start = s.index(after: i)
                guard let end = vdfStringEnd(s, from: start, limit: range.upperBound) else { return nil }
                let afterKey = s.index(after: end)
                if s[start..<end].lowercased() == want { return i..<afterKey }
                // Not our key: skip its string value or `{...}` subsection so we only match keys at this depth.
                var j = afterKey
                while j < range.upperBound, s[j].isWhitespace { j = s.index(after: j) }
                if j < range.upperBound, s[j] == "{" {
                    guard let close = vdfMatchingBrace(s, open: j) else { return nil }
                    i = s.index(after: close)
                } else if j < range.upperBound, s[j] == "\"" {
                    let vs = s.index(after: j)
                    guard let ve = vdfStringEnd(s, from: vs, limit: range.upperBound) else { return nil }
                    i = s.index(after: ve)
                } else {
                    i = afterKey
                }
                continue
            }
            i = s.index(after: i)
        }
        return nil
    }

    nonisolated private static func vdfStringValue(_ s: String, key: String, in range: Range<String.Index>) -> String? {
        guard let kr = vdfFindKey(s, key: key, in: range) else { return nil }
        var i = kr.upperBound
        while i < range.upperBound, s[i].isWhitespace { i = s.index(after: i) }
        guard i < range.upperBound, s[i] == "\"" else { return nil }
        let start = s.index(after: i)
        guard let end = vdfStringEnd(s, from: start, limit: range.upperBound) else { return nil }
        return vdfUnescape(String(s[start..<end]))
    }

    nonisolated private static func vdfSetStringValue(_ s: inout String, key: String, value: String, in range: Range<String.Index>) -> Bool {
        if let kr = vdfFindKey(s, key: key, in: range) {
            var i = kr.upperBound
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex, s[i] == "\"" else { return false }
            let start = s.index(after: i)
            guard let end = vdfStringEnd(s, from: start, limit: s.endIndex) else { return false }
            let old = vdfUnescape(String(s[start..<end]))
            if old == value { return false }
            s.replaceSubrange(start..<end, with: vdfEscape(value))
            return true
        }
        // Insert on its own line after the newline that follows `{`, not glued to `{` (that left a blank line before the next key).
        var at = range.lowerBound
        if at < range.upperBound, s[at] == "\n" { at = s.index(after: at) }
        let indent = vdfChildIndent(s, in: range) ?? "\t\t\t\t\t\t"
        let line = "\(indent)\"\(key)\"\t\t\"\(vdfEscape(value))\"\n"
        s.insert(contentsOf: line, at: at)
        return true
    }

    nonisolated private static func vdfRemoveStringKey(_ s: inout String, key: String, in range: Range<String.Index>) -> Bool {
        guard let kr = vdfFindKey(s, key: key, in: range) else { return false }
        var i = kr.upperBound
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "\"" else { return false }
        let start = s.index(after: i)
        guard let end = vdfStringEnd(s, from: start, limit: s.endIndex) else { return false }
        // Remove from start of the key's line through the newline after the value.
        var lineStart = kr.lowerBound
        while lineStart > s.startIndex {
            let p = s.index(before: lineStart)
            if s[p] == "\n" { break }
            lineStart = p
        }
        var lineEnd = s.index(after: end)
        if lineEnd < s.endIndex, s[lineEnd] == "\n" { lineEnd = s.index(after: lineEnd) }
        s.removeSubrange(lineStart..<lineEnd)
        return true
    }

    nonisolated private static func vdfChildIndent(_ s: String, in range: Range<String.Index>) -> String? {
        var i = range.lowerBound
        while i < range.upperBound {
            if s[i] == "\n" {
                let line = s.index(after: i)
                var j = line
                while j < range.upperBound, s[j] == "\t" || s[j] == " " { j = s.index(after: j) }
                if j < range.upperBound, s[j] == "\"" { return String(s[line..<j]) }
                i = line
                continue
            }
            if s[i] == "{" {
                guard let close = vdfMatchingBrace(s, open: i) else { return nil }
                i = s.index(after: close)
                continue
            }
            i = s.index(after: i)
        }
        return nil
    }

    nonisolated private static func vdfMatchingBrace(_ s: String, open: String.Index) -> String.Index? {
        var i = s.index(after: open), depth = 1, inStr = false, esc = false
        while i < s.endIndex {
            let c = s[i]
            if inStr {
                if esc { esc = false }
                else if c == "\\" { esc = true }
                else if c == "\"" { inStr = false }
            } else if c == "\"" { inStr = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return nil
    }

    nonisolated private static func vdfStringEnd(_ s: String, from: String.Index, limit: String.Index) -> String.Index? {
        var i = from, esc = false
        while i < limit {
            if esc { esc = false; i = s.index(after: i); continue }
            if s[i] == "\\" { esc = true; i = s.index(after: i); continue }
            if s[i] == "\"" { return i }
            i = s.index(after: i)
        }
        return nil
    }

    nonisolated private static func vdfEscape(_ v: String) -> String {
        v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    nonisolated private static func vdfUnescape(_ v: String) -> String {
        var out = "", i = v.startIndex, esc = false
        while i < v.endIndex {
            let c = v[i]
            if esc { out.append(c); esc = false }
            else if c == "\\" { esc = true }
            else { out.append(c) }
            i = v.index(after: i)
        }
        return out
    }
}
