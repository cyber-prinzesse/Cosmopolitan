import SwiftUI

// Item 36: what could go, biggest first: shader caches of games that are no longer installed (Steam's steamapps/shadercache/<app id>
// without that app's manifest), leftover installers (each bottle's installers folder), and Windows temp files (the Windows and user Temp
// folders). Nothing is deleted until you confirm: Settings asks, the command line needs --yes.
struct CleanupItem: Sendable, Hashable { let what: String; let path: String; let bytes: Int64 }
extension Model {
    nonisolated static func folderBytes(_ p: String) -> Int64 {
        if let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? 0) }   // one file (an installer)
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: p), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in en { if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true { n += Int64(v.totalFileAllocatedSize ?? 0) } }
        return n
    }
    nonisolated static func cleanupSuggestions(_ bottles: [String]) -> [CleanupItem] {
        let fm = FileManager.default; var out: [CleanupItem] = []
        func add(_ what: String, _ p: String) { let b = folderBytes(p); if b > 0 { out.append(CleanupItem(what: what, path: p, bytes: b)) } }
        for b in bottles {
            let c = "\(bottlesDir)/\(b)/drive_c", apps = "\(c)/Program Files (x86)/Steam/steamapps"
            for id in ((try? fm.contentsOfDirectory(atPath: apps + "/shadercache")) ?? []) where Int(id) != nil && !fm.fileExists(atPath: "\(apps)/appmanifest_\(id).acf") {
                add("Shader cache of a game that is no longer installed (Steam app \(id))", "\(apps)/shadercache/\(id)")
            }
            for dir in ["\(bottlesDir)/\(b)/installers", "\(c)/installers"] {
                for f in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []) where !f.hasPrefix(".") { add("Leftover installer \(f)", "\(dir)/\(f)") }
            }
            add("Windows temp files (\(b))", "\(c)/windows/temp")
            for u in ((try? fm.contentsOfDirectory(atPath: c + "/users")) ?? []) where !u.hasPrefix(".") { add("Temp files of Windows user \(u) (\(b))", "\(c)/users/\(u)/AppData/Local/Temp") }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }
    // Only what was listed and confirmed; a temp folder is emptied, not removed, and only while nothing runs in its bottle (a running
    // program, an installer above all, may still need its temp files).
    func applyCleanup(_ items: [CleanupItem]) {
        let fm = FileManager.default; var freed: Int64 = 0, done = 0
        for i in items {
            if i.path.hasSuffix("/Temp") || i.path.hasSuffix("/temp") {
                if prefixServer(i.path.components(separatedBy: "/drive_c/")[0]) != nil { log += "Kept \(i.what): a program is running there.\n"; continue }
                for f in ((try? fm.contentsOfDirectory(atPath: i.path)) ?? []) { try? fm.removeItem(atPath: "\(i.path)/\(f)") }
            } else { try? fm.removeItem(atPath: i.path) }
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
            if let items {
                if items.isEmpty { Text("Nothing to free up right now.").font(.caption).foregroundStyle(.secondary) }
                ForEach(items, id: \.self) { i in
                    Toggle(isOn: Binding(get: { chosen.contains(i) }, set: { if $0 { chosen.insert(i) } else { chosen.remove(i) } })) {
                        HStack { Text(i.what).lineLimit(1); Spacer(); Text(ByteCountFormatter.string(fromByteCount: i.bytes, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                if !items.isEmpty {
                    Button("Delete \(chosen.count) item\(chosen.count == 1 ? "" : "s")…") { confirm = true }.disabled(chosen.isEmpty)
                        .confirmationDialog("Delete \(ByteCountFormatter.string(fromByteCount: chosen.reduce(0) { $0 + $1.bytes }, countStyle: .file))? This can't be undone; games and saves are not touched.", isPresented: $confirm) {
                            Button("Delete", role: .destructive) { m.applyCleanup(Array(chosen)); chosen = []; self.items = nil; reload() }
                        }
                }
            } else { ProgressView("Measuring…").controlSize(.small) }
        }.task { reload() }
    }
    func reload() { let b = m.bottles; Task.detached { let r = Model.cleanupSuggestions(b); await MainActor.run { items = r } } }
}
