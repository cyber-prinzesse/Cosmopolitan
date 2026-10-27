import SwiftUI
import Metal
import SQLite3
import UniformTypeIdentifiers

// §6.4 Shader caches: where the translation layers and games keep compiled shaders, how big they are, and a way to clear, merge, or pre-warm them.
// DXMT stores portable Apple Metal AIR (.metallib / MTLB) blobs inside SQLite (shaders_320.db, table cache_26), which are hardware-independent
// across M1/M2/M3/M4 Macs and can be backed up inside the bottle, merged across players (like Valve's Fossilize), and pre-warmed into the
// local Mac's native Metal GPU cache before launch.
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
        var out: [(String, String)] = [("Steam shader cache", "\(b)/drive_c/Program Files (x86)/Steam/steamapps/shadercache"),
                                       ("Bottle portable DXMT shaders", bottleShaderDir())]
        let dxmtRoot = Model.dxmtCacheRoot()
        for e in ((try? fm.contentsOfDirectory(atPath: dxmtRoot)) ?? []).sorted() where !e.hasPrefix(".") {
            out.append(("DXMT shader cache: \(e)", "\(dxmtRoot)/\(e)"))
        }
        for d in (try? fm.contentsOfDirectory(atPath: "\(h)/Library/Caches")) ?? [] where d.lowercased().contains("d3dmetal") || d.lowercased().contains("dxmt") || d.lowercased().contains("metal") && d.lowercased().contains("shader") { out.append((d, "\(h)/Library/Caches/\(d)")) }
        let ue = shell("find '\(b)/drive_c/users' -maxdepth 6 -name '*.upipelinecache' 2>/dev/null | head -20").split(separator: "\n").map(String.init)
        for f in ue { out.append(("Unreal PSO cache: \((f as NSString).lastPathComponent)", f)) }
        return out.filter { fm.fileExists(atPath: $0.1) }
    }

    // Losslessly merges portable MTLB blobs from `src` (shaders_320.db) into `dst`, returning the total entry count in `dst`.
    @discardableResult nonisolated static func mergeShaderDB(from src: String, into dst: String) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { return shaderDBCount(dst) }
        try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: dst) { try? fm.copyItem(atPath: src, toPath: dst); return shaderDBCount(dst) }
        var db: OpaquePointer?
        guard sqlite3_open(dst, &db) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }
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
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM cache_26;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        return n
    }

    // Loads every cached MTLB (.metallib) blob in `dbPath` through the local Metal device to pre-populate macOS's native GPU shader cache.
    nonisolated static func prewarmShaderDB(_ dbPath: String) -> (libs: Int, funcs: Int, secs: Double) {
        let t0 = Date()
        guard FileManager.default.fileExists(atPath: dbPath), let dev = MTLCreateSystemDefaultDevice() else { return (0, 0, 0) }
        var db: OpaquePointer?; var stmt: OpaquePointer?; var libs = 0, funcs = 0
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return (0, 0, 0) }
        defer { sqlite3_close(db) }
        if sqlite3_prepare_v2(db, "SELECT value FROM cache_26;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_blob(stmt, 0) {
                    let len = Int(sqlite3_column_bytes(stmt, 0))
                    if len > 4, let lib = try? dev.makeLibrary(data: DispatchData(bytes: UnsafeRawBufferPointer(start: ptr, count: len))) {
                        libs += 1
                        for fn in lib.functionNames where lib.makeFunction(name: fn) != nil { funcs += 1 }
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return (libs, funcs, Date().timeIntervalSince(t0))
    }

    // Syncs a game's DXMT shader cache with `<bottle>/options/shaders/<exe>.shaders_320.db` and pre-warms the local Metal GPU cache before launch.
    func shaderSync(_ exe: String, phase: String) {
        let name = (exe as NSString).lastPathComponent, b = bottleOf(exe)
        guard !b.isEmpty, name.lowercased().hasSuffix(".exe") else { return }
        let live = "\(Model.dxmtCacheRoot())/\(name)/shaders_320.db"
        let saved = "\(bottleShaderDir(b))/\(name).shaders_320.db"
        if phase == "pull" {
            if FileManager.default.fileExists(atPath: saved) { _ = Model.mergeShaderDB(from: saved, into: live) }
            if FileManager.default.fileExists(atPath: live) {
                Task.detached(priority: .userInitiated) {
                    let r = Model.prewarmShaderDB(live)
                    if r.libs > 0 {
                        let msg = String(format: "Pre-warmed %d Metal shaders for %@ in %.2f s.\n", r.libs, name, r.secs)
                        await MainActor.run { logToFile(msg); self.log += msg }
                    }
                }
            }
        } else if phase == "push", FileManager.default.fileExists(atPath: live) {
            _ = Model.mergeShaderDB(from: live, into: saved)
        }
    }

    func prewarmBottleShaders() {
        let dxmtRoot = Model.dxmtCacheRoot(), savedDir = bottleShaderDir(), fm = FileManager.default
        var names = Set(((try? fm.contentsOfDirectory(atPath: dxmtRoot)) ?? []).filter { !$0.hasPrefix(".") })
        for f in ((try? fm.contentsOfDirectory(atPath: savedDir)) ?? []) where f.hasSuffix(".shaders_320.db") {
            names.insert(String(f.dropLast(".shaders_320.db".count)))
        }
        var totalLibs = 0, totalFuncs = 0, totalSecs = 0.0
        for name in names.sorted() {
            let live = "\(dxmtRoot)/\(name)/shaders_320.db", saved = "\(savedDir)/\(name).shaders_320.db"
            if fm.fileExists(atPath: saved) { _ = Model.mergeShaderDB(from: saved, into: live) }
            if fm.fileExists(atPath: live) { _ = Model.mergeShaderDB(from: live, into: saved) }
            let r = Model.prewarmShaderDB(live)
            totalLibs += r.libs; totalFuncs += r.funcs; totalSecs += r.secs
        }
        let msg = String(format: "Shader pre-warm (\(selected)): %d compiled Metal shaders (%d functions) across %d game(s) ready in %.3f s.\n", totalLibs, totalFuncs, names.count, totalSecs)
        logToFile(msg); log += msg
    }

    func importShaderCachePicker() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType.data]; p.allowsMultipleSelection = false
        p.message = "Select a DXMT shaders_320.db file (named <Game.exe>.shaders_320.db or inside a <Game.exe>/ folder) to merge into \(selected)."
        guard p.runModal() == .OK, let u = p.url else { return }
        let file = u.lastPathComponent
        let parent = u.deletingLastPathComponent().lastPathComponent
        let exeName = file.hasSuffix(".shaders_320.db") ? String(file.dropLast(".shaders_320.db".count)) : (parent.lowercased().hasSuffix(".exe") ? parent : "DarkSoulsRemastered.exe")
        let live = "\(Model.dxmtCacheRoot())/\(exeName)/shaders_320.db", saved = "\(bottleShaderDir())/\(exeName).shaders_320.db"
        let count = Model.mergeShaderDB(from: u.path, into: live)
        _ = Model.mergeShaderDB(from: live, into: saved)
        let r = Model.prewarmShaderDB(live)
        let msg = String(format: "Merged shader cache for %@: %d total shaders (%d pre-warmed in %.3f s).\n", exeName, count, r.libs, r.secs)
        logToFile(msg); log += msg
    }

    func shaderCacheReport() {
        var out = "── Shader caches (\(selected)) ──\n"
        for (n, p) in shaderCacheDirs() { out += "  \(sh("du -sh '\(p)' 2>/dev/null | cut -f1"))\t\(n)\n" }
        if shaderCacheDirs().isEmpty { out += "  none found yet (they appear after games have run)\n" }
        out += "Clearing forces games to recompile shaders on their next start (slower first minutes), useful after a driver update that produces glitches.\n──\n"
        logToFile(out); log += out
    }
    func clearShaderCaches() {
        guard sh("ps -axo command= | grep -c 'steamapps.common'").hasPrefix("0") else { log += "Shader caches: quit running games first.\n"; return }
        for (n, p) in shaderCacheDirs() { _ = sh("rm -rf '\(p)'"); log += "Cleared \(n)\n" }
    }
}
