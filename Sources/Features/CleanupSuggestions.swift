import SwiftUI

// Item 36: what could go, biggest first: shader caches of games that are no longer installed (Steam's steamapps/shadercache/<app id>
// without that app's manifest), leftover installers (each bottle's installers folder), and Windows temp files (the Windows and user Temp
// folders). Nothing is deleted until you confirm: Settings asks, the command line needs --yes.
// A temp item covers several folders (the bottle's windows/temp and every Windows user's Temp), shown as one line: the Windows
// user names come from the bottle template and mean nothing to the player.
struct CleanupItem: Sendable, Hashable {
    let what: String; let paths: [String]; let bytes: Int64
    var path: String { paths.joined(separator: " + ") }
}
extension Model {
    nonisolated static func folderBytes(_ p: String) -> Int64 {
        if let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? 0) }   // one file (an installer)
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in en { if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true { n += Int64(v.totalFileAllocatedSize ?? 0) } }
        return n
    }
    nonisolated static let cleanupShowBytes: Int64 = 100 << 20
    nonisolated static func cleanupSuggestions(_ bottles: [String]) -> [CleanupItem] {
        let fm = FileManager.default; var out: [CleanupItem] = []
        func add(_ what: String, _ ps: [String]) { let b = ps.reduce(Int64(0)) { $0 + folderBytes($1) }; if b > 0 { out.append(CleanupItem(what: what, paths: ps, bytes: b)) } }
        func add(_ what: String, _ p: String) { add(what, [p]) }
        for b in bottles {
            let c = "\(bottlesDir)/\(b)/drive_c", apps = "\(c)/Program Files (x86)/Steam/steamapps"
            for id in ((try? fm.contentsOfDirectory(atPath: apps + "/shadercache")) ?? []) where Int(id) != nil && !fm.fileExists(atPath: "\(apps)/appmanifest_\(id).acf") {
                add("Shader cache of a game that is no longer installed (Steam app \(id))", "\(apps)/shadercache/\(id)")
            }
            for dir in ["\(bottlesDir)/\(b)/installers", "\(c)/installers"] {
                for f in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []) where !f.hasPrefix(".") { add("Leftover installer \(f)", "\(dir)/\(f)") }
            }
            let users = ((try? fm.contentsOfDirectory(atPath: c + "/users")) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            add("Windows temp files (bottle \(b))", ["\(c)/windows/temp"] + users.map { "\(c)/users/\($0)/AppData/Local/Temp" })
        }
        return out.sorted { $0.bytes > $1.bytes }
    }
    // Only what was listed and confirmed; a temp folder is emptied, not removed, and only while nothing runs in its bottle (a running
    // program, an installer above all, may still need its temp files).
    func applyCleanup(_ items: [CleanupItem]) {
        let fm = FileManager.default; var freed: Int64 = 0, done = 0
        for i in items {
            if i.paths.allSatisfy({ $0.hasSuffix("/Temp") || $0.hasSuffix("/temp") }) {
                if prefixServer(i.paths[0].components(separatedBy: "/drive_c/")[0]) != nil { log += "Kept \(i.what): a program is running there.\n"; continue }
                for p in i.paths { for f in ((try? fm.contentsOfDirectory(atPath: p)) ?? []) { try? fm.removeItem(atPath: "\(p)/\(f)") } }
            } else { for p in i.paths { try? fm.removeItem(atPath: p) } }
            freed += i.bytes; done += 1
        }
        log += "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) (\(done) item\(done == 1 ? "" : "s"), confirmed).\n"
    }
}

// Settings › Free up space: the list with sizes; the chosen items go only after "Delete…" is confirmed.
struct CleanupList: View {
    @ObservedObject var m: Model
    @State var items: [CleanupItem]? = nil
    @State var chosen: Set<CleanupItem> = []
    @State var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let all = items {
                // Under 100 MB isn't worth a decision: the daily Clean up empties temp folders by itself.
                let items = all.filter { $0.bytes >= Model.cleanupShowBytes }
                if items.isEmpty { Text("Nothing to free up right now.").font(.caption).foregroundStyle(.secondary) }
                ForEach(items, id: \.self) { i in
                    Toggle(isOn: Binding(get: { chosen.contains(i) }, set: { if $0 { chosen.insert(i) } else { chosen.remove(i) } })) {
                        HStack { Text(i.what).lineLimit(1); Spacer(); Text(ByteCountFormatter.string(fromByteCount: i.bytes, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                if !chosen.isEmpty {
                    Button("Delete \(chosen.count) item\(chosen.count == 1 ? "" : "s")…") { confirm = true }
                        .confirmationDialog("Delete \(ByteCountFormatter.string(fromByteCount: chosen.reduce(0) { $0 + $1.bytes }, countStyle: .file))? This can't be undone; games and saves are not touched.", isPresented: $confirm) {
                            Button("Delete", role: .destructive) { m.applyCleanup(Array(chosen)); chosen = []; self.items = nil; reload() }
                        }
                }
            } else { ProgressView("Measuring…").controlSize(.small) }
        }.task { reload() }
    }
    func reload() { let b = m.bottles; Task.detached { let r = Model.cleanupSuggestions(b); await MainActor.run { items = r } } }
}
