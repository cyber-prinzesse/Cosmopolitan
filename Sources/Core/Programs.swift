import SwiftUI

// Display name = the program folder under Program Files, or the Steam library name for steamapps games.
var steamGames: [String: (id: String, name: String)] = [:]   // exe path -> appid/name from appmanifest_*.acf
func appName(_ p: String) -> String { steamGames[p]?.name ?? epicGames[p]?.name ?? appRoot(p).name }

// One tile per application. An app folder (Program Files*/<App>, steamapps/common/<Game>, GOG…/Games/<Game>, Games/Epic/<Game>) holds
// one program plus helpers (launchers' service exes, CEF browsers, 32/64-bit copies in x86/x86_64 subfolders, error reporters), and
// "Find apps" digs those out too. The tile keeps the exe that best looks like the program itself; the rest stays launchable by hand.
func appRoot(_ p: String) -> (root: String, name: String) {
    let parts = p.components(separatedBy: "/")
    var hit: Int? = nil   // deepest marker wins: Program Files (x86)/Steam/steamapps/common/<Game> groups by <Game>, Steam/bin/… by Steam
    for (i, part) in parts.enumerated() where i + 1 < parts.count - 1 {   // the exe's own folder is never the marker
        if ["Program Files", "Program Files (x86)", "common", "Games", "Epic", "GOG Games"].contains(part) { hit = i }
    }
    if let i = hit { return (parts[0...i + 1].joined(separator: "/"), parts[i + 1]) }
    let dir = (p as NSString).deletingLastPathComponent
    // Store installers are staged together in a bottle's installers folder: each goes by its own name (SteamSetup), not "installers".
    if (dir as NSString).lastPathComponent == "installers" { return (dir, ((p as NSString).lastPathComponent as NSString).deletingPathExtension) }
    return (dir, (dir as NSString).lastPathComponent)
}

// Stable identity for Library dedupe: prefer store appid, then CDPR/Unreal game root, then real path of the app folder (case-insensitive).
// Same game via manifest + plain exe, bootstrap + -Win64-Shipping, REDprelauncher + witcher3, /tmp vs /private/tmp, and two bottles share one key.
func libraryIdentity(_ p: String) -> String {
    if let g = steamGames[p] { return "steam:\(g.id)" }
    if let g = epicGames[p] { return "epic:\(g.id)" }
    let dir = (p as NSString).deletingLastPathComponent
    if let red = Model.redGame(dir) {
        return "red:" + realPath(red.exe).lowercased()
    }
    // Battle.net Launcher.exe and Battle.net.exe (and versioned Battle.net.NNNNN children) are one client.
    let parts = p.components(separatedBy: "/")
    if let i = parts.firstIndex(where: { $0.lowercased() == "battle.net" }) {
        return "battlenet:" + realPath(parts[0...i].joined(separator: "/")).lowercased()
    }
    // Unreal: Game.exe next to Engine/ and Binaries/Win64/*-Shipping.exe share the install root.
    let root = appRoot(p).root
    let engine = root + "/Engine", binaries = root + "/Binaries"
    if FileManager.default.fileExists(atPath: engine) || FileManager.default.fileExists(atPath: binaries) {
        return "ue:" + realPath(root).lowercased()
    }
    let base = (p as NSString).lastPathComponent.lowercased()
    if base.hasSuffix("-win64-shipping.exe") || base.hasSuffix("-shipping.exe") {
        return "ue:" + realPath(root).lowercased()
    }
    return "path:" + realPath(root).lowercased()
}

// Score which exe to keep for a tile. Size from attributes only (never a full read of a multi‑GB exe). Cache under the
// bottle's options/ or the app support folder — never beside the exe (a user-picked drive must not get .cosmo-score-* files).
func libraryExeScore(_ p: String) -> Int {
    let fm = FileManager.default
    let attrs = try? fm.attributesOfItem(atPath: p)
    let size = attrs?[.size] as? Int ?? 0
    let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    let bottle = { () -> String? in
        let pre = bottlesDir + "/"
        guard p.hasPrefix(pre), let b = p.dropFirst(pre.count).split(separator: "/").first else { return nil }
        return String(b)
    }()
    let leaf = (p as NSString).lastPathComponent
    let cache = bottle.map { "\(bottlesDir)/\($0)/options/.score-\(leaf)" }
        ?? "\(support)/cache/score-\(leaf.hashValue)-\(leaf)"
    let key = "\(size)|\(mtime)"
    if let c = try? String(contentsOfFile: cache, encoding: .utf8), c.hasPrefix(key + "\n"),
       let s = Int(c.components(separatedBy: "\n").dropFirst().first ?? "") { return s }

    let r = appRoot(p), baseName = (leaf as NSString).deletingPathExtension.lowercased()
    let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
    let depth = p.components(separatedBy: "/").count - r.root.components(separatedBy: "/").count
    var score = 100 - depth * 15
    if norm(baseName) == norm(r.name) { score += 60 }
    if ["galaxyclient", "battle.net launcher", "steam", "epicgameslauncher", "eadesktop", "ubisoftconnect", "upc"].contains(baseName) { score += 80 }
    if baseName.contains("launcher") && !baseName.contains("redprelauncher") { score += 25 }
    if baseName.contains("redprelauncher") || baseName == "redlauncher" { score -= 120 }   // CDPR: prefer witcher3 when both are candidates
    if baseName.hasSuffix("-win64-shipping") || baseName.hasSuffix("-shipping") { score += 90 }
    if ["x86", "x86_64", "x64", "win64", "win32", "bin", "binaries"].contains(((p as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()) { score += 10 }
    if ["cef", "bdk", "crashpad", "tools", "support", "redist", "_commonredist", "systeminfo"].contains(where: { p.lowercased().contains("/\($0)/") }) { score -= 100 }
    if baseName.hasPrefix("battle.net") && baseName != "battle.net launcher" { score -= 30 }
    if let red = Model.redGame((p as NSString).deletingLastPathComponent), realPath(red.exe) == realPath(p) { score += 100 }
    score += Int(min(size, 50_000_000) / 5_000_000)
    try? FileManager.default.createDirectory(atPath: (cache as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? "\(key)\n\(score)\n".write(toFile: cache, atomically: true, encoding: .utf8)
    return score
}

// Crash / error reporters, session monitors, system-info scanners — never tiles (Find apps and Program Files scans).
func isReporterOrMonitorExe(_ n: String) -> Bool {
    let n = n.lowercased()
    if ["unitycrashhandler64.exe", "unitycrashhandler32.exe", "unitycrashhandler.exe", "blizzarderror.exe",
        "gamesessionmonitor.exe", "fmsiscan.exe", "systeminfo.exe"].contains(n) { return true }
    if n.contains("errorreporter") || n.contains("crashhandler") || n.contains("crashpad") { return true }
    if n.hasSuffix("error.exe") && (n.contains("blizzard") || n.contains("agent")) { return true }
    if n.contains("sessionmonitor") || n.contains("gamesession") { return true }
    if n.hasPrefix("easyanticheat") || n.hasPrefix("eac_") || n.contains("battleye") || n.hasPrefix("beclient") { return true }
    return false
}

// Helpers that must never become tiles. Store-backed paths (steamGames / epicGames) are never helpers: Steam often points at
// REDprelauncher.exe while launcher-configuration.json names witcher3.exe — dropping the Steam entry removed the whole tile.
func isHelperExe(_ p: String) -> Bool {
    if steamGames[p] != nil || epicGames[p] != nil { return false }
    let n = (p as NSString).lastPathComponent.lowercased()
    if skipExes.contains(where: { n.contains($0) }) { return true }
    if isReporterOrMonitorExe(n) { return true }
    // REDprelauncher when the real game exe from launcher-configuration.json is present (and this path is not the Steam tile).
    if n == "redprelauncher.exe" || n == "redlauncher.exe", Model.redGame((p as NSString).deletingLastPathComponent) != nil { return true }
    return false
}

// True for helper-shaped files even when they are the Steam entry (used when choosing which exe under an installdir to keep).
func isHelperCandidate(_ p: String) -> Bool {
    let n = (p as NSString).lastPathComponent.lowercased()
    if skipExes.contains(where: { n.contains($0) }) { return true }
    if isReporterOrMonitorExe(n) { return true }
    if n == "redprelauncher.exe" || n == "redlauncher.exe" { return true }
    return false
}

// One path per identity. Prefer store-backed entries (and their display names via steamGames/epicGames). Order of first appearance kept.
func dedupe(_ found: [String]) -> [String] {
    var best: [String: (path: String, score: Int)] = [:], order: [String] = []
    for p in found where !isHelperExe(p) {
        let key = libraryIdentity(p)
        let score = libraryExeScore(p) + (steamGames[p] != nil || epicGames[p] != nil ? 200 : 0)   // store identity wins over a plain exe
        if let b = best[key], b.score >= score { continue }
        if best[key] == nil { order.append(key) }
        best[key] = (p, score)
    }
    return order.compactMap { best[$0]?.path }
}

// Cross-bottle: same identity once. Prefer a path in `preferBottle` when present. Fills `alts` with every other bottle's path for that game.
func dedupeLibrary(_ found: [String], preferBottle: String, alts: inout [String: [String]]) -> [String] {
    struct Cand { var path: String; var score: Int; var bottle: String }
    var byKey: [String: [Cand]] = [:], order: [String] = []
    for p in found where !isHelperExe(p) {
        let key = libraryIdentity(p)
        let bottle = { () -> String in
            let pre = bottlesDir + "/"
            guard p.hasPrefix(pre), let b = p.dropFirst(pre.count).split(separator: "/").first else { return "" }
            return String(b)
        }()
        let score = libraryExeScore(p) + (steamGames[p] != nil || epicGames[p] != nil ? 200 : 0) + (bottle == preferBottle ? 50 : 0)
        if byKey[key] == nil { order.append(key) }
        byKey[key, default: []].append(Cand(path: p, score: score, bottle: bottle))
    }
    alts = [:]
    var out: [String] = []
    for key in order {
        guard let cands = byKey[key], let win = cands.max(by: { $0.score < $1.score }) else { continue }
        out.append(win.path)
        let others = cands.filter { realPath($0.path).lowercased() != realPath(win.path).lowercased() }.map(\.path)
        if !others.isEmpty { alts[win.path] = others }
    }
    return out
}
