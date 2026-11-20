import Foundation

// Item 30: save backups from the Ludusavi manifest (MIT, github.com/mtkennerly/ludusavi-manifest). The manifest is fetched at runtime into the
// cache (at most weekly) and never bundled. A game's Windows save paths are resolved inside its own bottle and cloned (APFS, no extra space
// until they change) into support/save-backups/<game>/<stamp> <reason>/, newest 5 kept. Taken before Repair, a driver change and a game update.
extension Model {
    nonisolated static var ludusaviPath: String { support + "/cache/ludusavi-manifest.yaml" }
    nonisolated static func refreshLudusavi(force: Bool = false) -> String {
        let p = ludusaviPath, fm = FileManager.default
        if !force, let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 7 * 86400 { return "Ludusavi manifest is current." }
        let url = (isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_URL_ludusavi"] : nil) ?? "https://raw.githubusercontent.com/mtkennerly/ludusavi-manifest/master/data/manifest.yaml"
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = shell("curl -fsSL --max-time 300 -o \(shq("\(p).part")) \(shq("\(url)")) && mv \(shq("\(p).part")) \(shq("\(p)"))")
        ludusaviLock.lock(); ludusaviIndex = nil; ludusaviLock.unlock()
        return fm.fileExists(atPath: p) ? "Ludusavi manifest: \(loadLudusavi().count) games." : "Ludusavi manifest could not be downloaded."
    }
    struct SaveRule: Sendable { let path: String; let oses: [String]; let stores: [String] }
    struct SaveGame: Sendable { let name: String; var rules: [SaveRule] = []; var steam = ""; var installDirs: [String] = [] }
    nonisolated(unsafe) private static var ludusaviIndex: [SaveGame]? = nil
    nonisolated private static let ludusaviLock = NSLock()
    // A line reader for the manifest's fixed shape (game → files → path → when/tags, steam → id, installDir → name), no YAML library.
    nonisolated static func loadLudusavi() -> [SaveGame] {
        ludusaviLock.lock(); defer { ludusaviLock.unlock() }
        if let i = ludusaviIndex { return i }
        var games: [SaveGame] = [], cur: SaveGame? = nil, section = "", path: String? = nil, oses: [String] = [], stores: [String] = []
        func unq(_ s: Substring) -> String { var t = s.trimmingCharacters(in: .whitespaces); if t.hasSuffix(": {}") { t = String(t.dropLast(4)) } else if t.hasSuffix(":") { t = String(t.dropLast()) }
            if t.count >= 2, t.first == "\"" || t.first == "'", t.last == t.first { t = String(t.dropFirst().dropLast()) }; return t.replacingOccurrences(of: "\\\"", with: "\"") }
        func flush() { if let p = path { cur?.rules.append(SaveRule(path: p, oses: oses, stores: stores)) }; path = nil; oses = []; stores = [] }
        let text = (try? String(contentsOfFile: ludusaviPath, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let indent = line.prefix { $0 == " " }.count, body = line.dropFirst(indent)
            if body.hasPrefix("#") { continue }
            if indent == 0 { flush(); if let c = cur { games.append(c) }; cur = SaveGame(name: unq(body)); section = ""; continue }
            if indent == 2 { flush(); section = unq(body); continue }
            if section == "files" {
                if indent == 4 { flush(); path = unq(body) }
                else if body.hasPrefix("- os:") { oses.append(String(body.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                else if body.hasPrefix("os:") { oses.append(String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)) }
                else if body.hasPrefix("- store:") || body.hasPrefix("store:") { stores.append(String(body.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)) }
            } else if section == "steam", indent == 4, body.hasPrefix("id:") { cur?.steam = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            else if section == "installDir", indent == 4 { cur?.installDirs.append(unq(body)) }
        }
        flush(); if let c = cur { games.append(c) }
        ludusaviIndex = games; return games
    }
    // The game's entry: by Steam app id, else by its install folder or name.
    func saveGame(_ exe: String) -> SaveGame? {
        let games = Model.loadLudusavi(), folder = (appRoot(exe).root as NSString).lastPathComponent, n = Model.normName(steamGames[exe]?.name ?? appName(exe))
        if let id = steamGames[exe]?.id, let g = games.first(where: { $0.steam == id }) { return g }
        return games.first { g in g.installDirs.contains { $0.caseInsensitiveCompare(folder) == .orderedSame } || Model.normName(g.name) == n }
    }
    // Resolved, existing save paths inside the game's bottle (Windows rules only; another store's rules skipped).
    func savePaths(_ exe: String) -> [String] {
        guard let g = saveGame(exe) else { return [] }
        let c = "\(bottlesDir)/\(bottleOf(exe))/drive_c", fm = FileManager.default
        let user = ((try? fm.contentsOfDirectory(atPath: c + "/users")) ?? []).first { $0 != "Public" && !$0.hasPrefix(".") } ?? NSUserName()
        let home = "\(c)/users/\(user)", steamRoot = "\(c)/Program Files (x86)/Steam"
        let base = steamGames[exe] != nil ? ((exe as NSString).deletingLastPathComponent.components(separatedBy: "/steamapps/common/").last.map { "\(steamRoot)/steamapps/common/" + ($0.split(separator: "/").first.map(String.init) ?? "") } ?? appRoot(exe).root) : appRoot(exe).root
        let store = steamGames[exe] != nil ? "steam" : ""
        let map = ["<base>": base, "<root>": steamRoot, "<home>": home, "<winAppData>": home + "/AppData/Roaming", "<winLocalAppData>": home + "/AppData/Local",
                   "<winLocalAppDataLow>": home + "/AppData/LocalLow", "<winDocuments>": home + "/Documents", "<winPublic>": c + "/users/Public",
                   "<winProgramData>": c + "/ProgramData", "<winDir>": c + "/windows", "<storeUserId>": "*", "<storeGameId>": steamGames[exe]?.id ?? "*",
                   "<osUserName>": user, "<game>": g.name]
        var out: [String] = []
        for r in g.rules where (r.oses.isEmpty || r.oses.contains("windows")) && (r.stores.isEmpty || r.stores.contains(store)) {
            var p = r.path; for (k, v) in map { p = p.replacingOccurrences(of: k, with: v) }
            guard !p.contains("<") else { continue }   // a placeholder that has no meaning in a bottle (Linux/Mac paths)
            p = p.replacingOccurrences(of: "**", with: "*")   // ponytail: one level for "**"; a recursive walk if a manifest entry needs it
            var gt = glob_t(); defer { globfree(&gt) }
            if glob(p, 0, nil, &gt) == 0 { for i in 0..<Int(gt.gl_matchc) { if let s = gt.gl_pathv[i] { out.append(String(cString: s)) } } }
        }
        return Array(Set(out)).filter { ($0 as NSString).standardizingPath.hasPrefix((c as NSString).standardizingPath + "/") }.sorted()   // a manifest rule like "/" stays out
    }
    // Clones the save paths into support/save-backups/<game>/<stamp> <reason>/ (paths under drive_c kept); keeps the newest 5 per game.
    @discardableResult func backupSaves(_ exe: String, _ reason: String) -> String {
        let paths = savePaths(exe); guard !paths.isEmpty, let g = saveGame(exe) else { return "" }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        // The name comes from a downloaded manifest (SEC-004): one plain folder name under save-backups/, never "", "." or ".."
        // (the prune below would then delete support folders). Leading dots go, so hidden names can't be made either.
        var safe = g.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while safe.hasPrefix(".") { safe.removeFirst() }
        if safe.trimmingCharacters(in: .whitespaces).isEmpty { safe = "game" }
        let root = "\(support)/save-backups/\(safe)", dst = "\(root)/\(f.string(from: Date())) \(reason)"
        let c = "\(bottlesDir)/\(bottleOf(exe))/drive_c/", fm = FileManager.default
        for p in paths {
            let rel = p.hasPrefix(c) ? String(p.dropFirst(c.count)) : (p as NSString).lastPathComponent
            guard !rel.split(separator: "/").contains("..") else { continue }   // a manifest path with ".." must not land outside this backup
            try? fm.createDirectory(atPath: ("\(dst)/\(rel)" as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = shell("cp -cR \(shq(p)) \(shq("\(dst)/\(rel)"))")
        }
        for old in (((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: >)).dropFirst(5) { try? fm.removeItem(atPath: "\(root)/\(old)") }
        let note = "Saves of \(g.name) backed up (\(reason)): \(paths.count) item\(paths.count == 1 ? "" : "s") → save-backups/\(safe)\n"
        logToFile(note); log += note; return note
    }
    // Before Repair or a bottle-wide driver change: every game in that bottle that the manifest knows.
    func backupBottleSaves(_ bottle: String, _ reason: String) { for p in library where bottleOf(p) == bottle { backupSaves(p, reason) } }
    // A Steam game with an update pending (its app manifest says so) gets one backup per pending update, before Steam installs it.
    func backupBeforeUpdates() {
        for p in library where steamGames[p] != nil {
            let b = bottleOf(p), id = steamGames[p]!.id, acf = "\(bottlesDir)/\(b)/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_\(id).acf"
            guard let t = try? String(contentsOfFile: acf, encoding: .utf8), let flags = t.range(of: "\"StateFlags\"\\s+\"[0-9]+\"", options: .regularExpression)
                    .flatMap({ Int(t[$0].components(separatedBy: "\"").dropLast().last ?? "") }), flags & (2 | 256 | 1024 | 1048576) != 0 else { continue }
            let target = t.range(of: "\"TargetBuildID\"\\s+\"[0-9]+\"", options: .regularExpression).map { String(t[$0]) } ?? "\(flags)"
            let mark = "\(bottlesDir)/\(b)/options/.saves-before-update-\(id)"
            if (try? String(contentsOfFile: mark, encoding: .utf8)) == target { continue }
            if !backupSaves(p, "before game update").isEmpty { try? target.write(toFile: mark, atomically: true, encoding: .utf8) }
        }
    }
}
