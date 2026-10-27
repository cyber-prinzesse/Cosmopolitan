import SwiftUI
import SQLite3
import UniformTypeIdentifiers

// §6.4 Shader caches: where the translation layers and games keep compiled shaders, how big they are, and a way to clear, back up, or merge them.
// DXMT stores portable Apple Metal AIR (.metallib / MTLB) blobs inside SQLite (shaders_320.db, table cache_26), which are hardware-independent
// across Apple Silicon Macs, so each game's database is kept in the bottle too (options/shaders) and survives macOS purging /var/folders.
// DXMT runs the database in WAL mode with most rows still in the -wal file, so it is only ever copied through SQLite, never as a file.
// Pre-warming is not possible from outside the game: Metal's GPU binary cache is per process (DXMT gives each exe its own com.apple.metal).
extension Model {
    nonisolated static func dxmtCacheRoot() -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(Int32(_CS_DARWIN_USER_CACHE_DIR), &buf, buf.count) > 0 {
            return (String(cString: buf) as NSString).standardizingPath + "/dxmt"
        }
        return ((NSTemporaryDirectory() as NSString).deletingLastPathComponent as NSString).appendingPathComponent("C/dxmt")
    }

    func bottleShaderDir(_ bottle: String? = nil) -> String { "\(bottlesDir)/\(bottle ?? selected)/options/shaders" }

    func shaderCacheDirs() -> [(String, String)] {
        let b = "\(bottlesDir)/\(selected)", h = NSHomeDirectory(), fm = FileManager.default
        var out: [(String, String)] = [("Steam shader cache", "\(b)/drive_c/Program Files (x86)/Steam/steamapps/shadercache")]
        let dxmtRoot = Model.dxmtCacheRoot()
        for e in ((try? fm.contentsOfDirectory(atPath: dxmtRoot)) ?? []).sorted() where !e.hasPrefix(".") {
            out.append(("DXMT shader cache: \(e)", "\(dxmtRoot)/\(e)"))
        }
        for d in (try? fm.contentsOfDirectory(atPath: "\(h)/Library/Caches")) ?? [] where d.lowercased().contains("d3dmetal") || d.lowercased().contains("dxmt") || d.lowercased().contains("metal") && d.lowercased().contains("shader") { out.append((d, "\(h)/Library/Caches/\(d)")) }
        let ue = shell("find '\(b)/drive_c/users' -maxdepth 6 -name '*.upipelinecache' 2>/dev/null | head -20").split(separator: "\n").map(String.init)
        for f in ue { out.append(("Unreal PSO cache: \((f as NSString).lastPathComponent)", f)) }
        return out.filter { fm.fileExists(atPath: $0.1) }
    }

    // True when `path` is a plain DXMT shader database: exactly the cache_26 table (no views or triggers) and only MTLB blobs in it.
    // Run on anything imported before SQLite attaches it, since the rows end up in the shaders a game executes.
    nonisolated static func isDXMTShaderDB(_ path: String) -> Bool {
        var db: OpaquePointer?; var stmt: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        var schema: [String] = []
        if sqlite3_prepare_v2(db, "SELECT type || ':' || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_autoindex_%';", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW { schema.append(String(cString: sqlite3_column_text(stmt, 0))) }
            sqlite3_finalize(stmt)
        }
        guard schema == ["table:cache_26"] else { return false }
        var bad = -1
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM cache_26 WHERE typeof(key) != 'blob' OR typeof(value) != 'blob' OR substr(value, 1, 4) != x'4D544C42';", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { bad = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        return bad == 0
    }

    // Losslessly merges MTLB blobs from `src` (shaders_320.db) into `dst`, creating `dst` if needed, and returns the entry count in `dst`.
    // Always through SQLite (ATTACH reads the WAL too); a file copy would miss every row DXMT has not checkpointed yet.
    @discardableResult nonisolated static func mergeShaderDB(from src: String, into dst: String) -> Int {
        guard FileManager.default.fileExists(atPath: src) else { return shaderDBCount(dst) }
        try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(dst, &db) == SQLITE_OK, let db else { sqlite3_close(db); return 0 }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)   // a running game may hold the write lock for a moment
        _ = sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS cache_26 (key BLOB PRIMARY KEY, value BLOB NOT NULL);", nil, nil, nil)
        let esc = src.replacingOccurrences(of: "'", with: "''")
        if sqlite3_exec(db, "ATTACH DATABASE '\(esc)' AS src;", nil, nil, nil) == SQLITE_OK {
            _ = sqlite3_exec(db, "INSERT OR IGNORE INTO main.cache_26 SELECT key, value FROM src.cache_26;", nil, nil, nil)
            _ = sqlite3_exec(db, "DETACH DATABASE src;", nil, nil, nil)
        }
        return shaderDBCount(dst)
    }

    nonisolated static func shaderDBCount(_ path: String) -> Int {
        var db: OpaquePointer?; var stmt: OpaquePointer?; var n = 0
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return 0 }
        defer { sqlite3_close(db) }
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM cache_26;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        return n
    }

    // A process (the game, under Wine) has this DXMT cache open; writing to it or deleting it then is unsafe.
    nonisolated static func shaderCacheInUse(_ path: String) -> Bool {
        !shell("lsof -t +D '\(path.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null | head -1").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Before launch: restore a game's DXMT cache from the bottle when macOS has purged it. After exit: save it into the bottle (off the main thread).
    func shaderSync(_ exe: String, phase: String) {
        let name = (exe as NSString).lastPathComponent, b = bottleOf(exe)
        guard !b.isEmpty, name.lowercased().hasSuffix(".exe"), !exe.contains("/installers/") else { return }
        let live = "\(Model.dxmtCacheRoot())/\(name)/shaders_320.db"
        let saved = "\(bottleShaderDir(b))/\(name).shaders_320.db"
        let fm = FileManager.default
        if phase == "pull" {
            // Only when the live cache is gone: otherwise it already holds everything the last push saved.
            if fm.fileExists(atPath: saved), !fm.fileExists(atPath: live) {
                let n = Model.mergeShaderDB(from: saved, into: live)
                if n > 0 { let msg = "Restored \(n) DXMT shaders for \(name) from the bottle.\n"; logToFile(msg); log += msg }
            }
        } else if phase == "push", fm.fileExists(atPath: live) {
            Task.detached(priority: .utility) { _ = Model.mergeShaderDB(from: live, into: saved) }
        }
    }

    // Repair › Shader caches › Back up: saves every DXMT cache this bottle has used into the bottle, and restores purged ones.
    func backupBottleShaders(wait: Bool = false) {   // wait: the CLI prints the log and exits right after
        let savedDir = bottleShaderDir(), bottle = selected
        if wait { let msg = Model.backupShaders(savedDir, bottle: bottle); logToFile(msg); log += msg; return }
        Task.detached(priority: .userInitiated) {
            let msg = Model.backupShaders(savedDir, bottle: bottle)
            await MainActor.run { logToFile(msg); self.log += msg }
        }
    }
    nonisolated static func backupShaders(_ savedDir: String, bottle: String) -> String {
        let fm = FileManager.default, dxmtRoot = dxmtCacheRoot()
        let names = ((try? fm.contentsOfDirectory(atPath: savedDir)) ?? []).filter { $0.hasSuffix(".shaders_320.db") }.map { String($0.dropLast(".shaders_320.db".count)) }
        guard !names.isEmpty else { return "Shader backup (\(bottle)): nothing yet — a game's DXMT shaders are saved into the bottle when it exits.\n" }
        var saved = 0, restored = 0, busy: [String] = []
        for name in names.sorted() {
            let live = "\(dxmtRoot)/\(name)/shaders_320.db", backup = "\(savedDir)/\(name).shaders_320.db"
            if fm.fileExists(atPath: live) {
                if shaderCacheInUse("\(dxmtRoot)/\(name)") { busy.append(name); continue }
                mergeShaderDB(from: live, into: backup); saved += 1
            } else { mergeShaderDB(from: backup, into: live); restored += 1 }
        }
        var msg = "Shader backup (\(bottle)): \(saved) game(s) saved into the bottle, \(restored) restored after a macOS purge.\n"
        if !busy.isEmpty { msg += "  skipped while running: \(busy.joined(separator: ", "))\n" }
        return msg
    }

    func importShaderCachePicker() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType.data]; p.allowsMultipleSelection = false
        p.message = "Select a DXMT shaders_320.db file (named <Game.exe>.shaders_320.db or inside a <Game.exe>/ folder) to merge into \(selected)."
        guard p.runModal() == .OK, let u = p.url else { return }
        let file = u.lastPathComponent, parent = u.deletingLastPathComponent().lastPathComponent
        let exeName = file.hasSuffix(".shaders_320.db") ? String(file.dropLast(".shaders_320.db".count)) : parent
        guard exeName.lowercased().hasSuffix(".exe") else {
            log += "Shader import: can't tell which game \(file) belongs to. Rename it <Game.exe>.shaders_320.db or put it in a folder named after the .exe.\n"; return
        }
        let src = u.path, liveDir = "\(Model.dxmtCacheRoot())/\(exeName)", saved = "\(bottleShaderDir())/\(exeName).shaders_320.db"
        Task.detached(priority: .userInitiated) {
            let msg: String
            if !Model.isDXMTShaderDB(src) { msg = "Shader import: \(file) is not a plain DXMT shader cache (only a cache_26 table of Metal libraries is accepted). Nothing changed.\n" }
            else if Model.shaderCacheInUse(liveDir) { msg = "Shader import: quit \(exeName) first.\n" }
            else {
                let n = Model.mergeShaderDB(from: src, into: "\(liveDir)/shaders_320.db")
                Model.mergeShaderDB(from: "\(liveDir)/shaders_320.db", into: saved)
                msg = "Merged shader cache for \(exeName): \(n) shaders now cached (also saved into the bottle).\n"
            }
            await MainActor.run { logToFile(msg); self.log += msg }
        }
    }

    func shaderCacheReport() {
        var out = "── Shader caches (\(selected)) ──\n"
        for (n, p) in shaderCacheDirs() { out += "  \(sh("du -sh '\(p)' 2>/dev/null | cut -f1"))\t\(n)\n" }
        if shaderCacheDirs().isEmpty { out += "  none found yet (they appear after games have run)\n" }
        let saved = bottleShaderDir()
        if FileManager.default.fileExists(atPath: saved) { out += "  \(sh("du -sh '\(saved)' 2>/dev/null | cut -f1"))\tDXMT shaders saved in the bottle (kept by Clear all)\n" }
        out += "Clearing forces games to recompile shaders on their next start (slower first minutes), useful after a driver update that produces glitches.\n──\n"
        logToFile(out); log += out
    }
    func clearShaderCaches() {
        guard sh("ps -axo command= | grep -c 'steamapps.common'").hasPrefix("0"), !Model.shaderCacheInUse(Model.dxmtCacheRoot()) else { log += "Shader caches: quit running games first.\n"; return }
        for (n, p) in shaderCacheDirs() { _ = sh("rm -rf '\(p)'"); log += "Cleared \(n)\n" }
    }
    // The bottle's saved DXMT shaders: Clear all keeps them (they restore at the next start); this drops them too, e.g. after a bad import.
    func clearSavedShaders() {
        _ = sh("rm -rf '\(bottleShaderDir())'"); log += "Deleted the DXMT shaders saved in \(selected).\n"
    }
}
