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
func dedupe(_ found: [String]) -> [String] {
    var best: [String: (path: String, score: Int)] = [:], order: [String] = []
    for p in found {
        let key = steamGames[p] != nil || epicGames[p] != nil ? p : appRoot(p).root   // store games are already one per title
        let r = appRoot(p), name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let depth = p.components(separatedBy: "/").count - r.root.components(separatedBy: "/").count   // 1 = directly in the app folder
        var score = 100 - depth * 15
        if norm(name) == norm(r.name) { score += 60 }                                   // StarCraft/StarCraft.exe
        if ["galaxyclient", "battle.net launcher", "steam", "epicgameslauncher"].contains(name) { score += 80 }
        if name.contains("launcher") { score += 25 }
        if ["x86", "x86_64", "x64", "win64", "win32", "bin", "binaries"].contains(((p as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()) { score += 10 }   // arch subfolders beat cef/bdk
        if ["cef", "bdk", "crashpad", "tools", "support", "redist", "_commonredist"].contains(where: { p.lowercased().contains("/\($0)/") }) { score -= 100 }
        if name.hasPrefix("battle.net") && name != "battle.net launcher" { score -= 30 }  // Battle.net.exe is the launcher's child
        score += Int(min((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int ?? 0, 50_000_000) / 5_000_000)   // 0–10 by size
        if let b = best[key], b.score >= score { continue }
        if best[key] == nil { order.append(key) }
        best[key] = (p, score)
    }
    return order.compactMap { best[$0]?.path }
}
