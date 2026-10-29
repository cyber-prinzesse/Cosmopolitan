import SwiftUI

extension Model {
    // Item 26: a clonefile(2) copy of the whole bottle (one call: 0.5 s for 28 000 files, no extra disk until the bottle diverges) before
    // Repair, a driver switch, a registry sweep, a Windows-version change, installs and the other risky writes. Hidden as
    // .auto-<bottle>-<stamp>; the newest 3 per bottle are kept, for 3 days. Never a full copy: if cloning fails (another volume, not APFS) there is
    // no snapshot and the log says why.
    nonisolated static let snapStamp = "yyyyMMdd-HHmmss"
    @discardableResult nonisolated static func snapshot(_ bottle: String, _ reason: String) -> (path: String?, note: String) {
        guard !bottle.isEmpty, FileManager.default.fileExists(atPath: "\(bottlesDir)/\(bottle)/drive_c") else { return (nil, "") }
        let f = DateFormatter(); f.dateFormat = snapStamp
        let bak = "\(bottlesDir)/.auto-\(bottle)-\(f.string(from: Date()))"
        if FileManager.default.fileExists(atPath: bak) { return (bak, "") }   // one per second is plenty
        guard clonefile(realPath("\(bottlesDir)/\(bottle)"), bak, UInt32(CLONE_NOFOLLOW)) == 0 else {
            return (nil, "Snapshot skipped (\(reason)): \(String(cString: strerror(errno))). Only APFS clones are made, never full copies.\n")
        }
        try? reason.write(toFile: bak + "/.snapshot-reason", atomically: false, encoding: .utf8)
        let pruned = pruneSnapshots(bottle)
        return (bak, "Snapshot (\(reason)): \((bak as NSString).lastPathComponent)" + (pruned.isEmpty ? "" : "; removed the oldest: " + pruned.joined(separator: ", ")) + "\n")
    }
    @discardableResult func snapshot(_ reason: String) -> String? { let r = Model.snapshot(selected, reason); log += r.note; return r.path }
    // This bottle's snapshots, newest first. The stamp must follow the prefix exactly, so bottle "Steam" never lists "Steam-2"'s.
    nonisolated static func snapshotList(_ bottle: String) -> [(path: String, when: String, reason: String)] {
        let pre = ".auto-\(bottle)-"
        return ((try? FileManager.default.contentsOfDirectory(atPath: bottlesDir)) ?? []).filter { n in
            n.hasPrefix(pre) && n.dropFirst(pre.count).count == snapStamp.count && n.dropFirst(pre.count).allSatisfy { $0.isASCII && ($0.isNumber || $0 == "-") }
        }.sorted(by: >).map { n in
            let p = "\(bottlesDir)/\(n)"
            return (p, String(n.dropFirst(pre.count)), (try? String(contentsOfFile: p + "/.snapshot-reason", encoding: .utf8)) ?? "backup")
        }
    }
    func snapshots() -> [(path: String, when: String, reason: String)] { Model.snapshotList(selected) }
    // A snapshot is the undo for a change that just went wrong, which shows at the next launch or two, so it lives 3 days. Kept longer it
    // costs: macOS's Storage settings count every clone at the bottle's full size (three of a 97 GB Steam bottle showed as 425 GB of
    // "Applications" on 2026-10-28, for 0.7 GB they really held), and each game update since makes it hold the replaced files for real.
    nonisolated static let snapMaxAge: TimeInterval = 3 * 86400
    // `names`: the bottles folder's entries; the age is the stamp in the name (the folder's date changes when Wine writes to the clone).
    nonisolated static func expiredSnapshots(_ names: [String], now: Date = Date()) -> [String] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = snapStamp
        return names.compactMap { n in
            guard n.hasPrefix(".auto-"), let d = f.date(from: String(n.suffix(snapStamp.count))), now.timeIntervalSince(d) > snapMaxAge else { return nil }
            return "\(bottlesDir)/\(n)"
        }
    }
    @discardableResult nonisolated static func pruneSnapshots(_ bottle: String, keep: Int = 3) -> [String] {
        let list = snapshotList(bottle), old = Set(expiredSnapshots(list.map { ($0.path as NSString).lastPathComponent }))
        return discardSnapshots(list.enumerated().filter { $0.offset >= keep || old.contains($0.element.path) }.map(\.element.path))
    }
    // Each one is renamed out of the list first (atomic, so a half-deleted snapshot is never offered for a rollback), then deleted in the
    // background; leftovers of an interrupted delete go the next time.
    @discardableResult nonisolated static func discardSnapshots(_ paths: [String]) -> [String] {
        let gone = paths.compactMap { p -> String? in
            let n = (p as NSString).lastPathComponent
            return n.hasPrefix(".auto-") && rename(p, "\(bottlesDir)/.deleting-\(n)") == 0 ? n : nil
        }
        Task.detached(priority: .background) {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: bottlesDir)) ?? [] where n.hasPrefix(".deleting-.auto-") { try? FileManager.default.removeItem(atPath: "\(bottlesDir)/\(n)") }
        }
        return gone
    }
    // Disk the snapshots hold that the bottle itself no longer uses: each snapshot file whose live counterpart is gone or was rewritten
    // since (size or modification date differ), counted once across snapshots (same path, size and date = one old version, shared by the
    // clones). File-level, so a big file patched in place counts whole: an upper bound, never an undercount.
    nonisolated static func snapshotDiskUse(_ bottle: String) -> Int64 {
        let live = "\(bottlesDir)/\(bottle)", fm = FileManager.default
        var seen = Set<String>(), total: Int64 = 0
        for s in snapshotList(bottle) {
            // Path-based: relative paths as they are (URL enumeration rewrites /private/tmp to /tmp), symlinks such as z: never followed.
            guard let en = fm.enumerator(atPath: s.path) else { continue }
            while let rel = en.nextObject() as? String {
                guard let a = en.fileAttributes, a[.type] as? FileAttributeType == .typeRegular, rel != ".snapshot-reason" else { continue }
                let size = (a[.size] as? NSNumber)?.int64Value ?? 0, date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let l = try? fm.attributesOfItem(atPath: "\(live)/\(rel)")
                if (l?[.size] as? NSNumber)?.int64Value == size, (l?[.modificationDate] as? Date)?.timeIntervalSince1970 == date { continue }   // still the bottle's
                if seen.insert("\(rel)|\(size)|\(date)").inserted { total += size }
            }
        }
        return total
    }
    // One click (plus the confirmation). Only this bottle's Wine programs are stopped (its own wineserver), never other bottles or Mac
    // processes. The current state is kept as a snapshot first, so a rollback can itself be undone.
    func rollback(to snap: String) {
        let b = selected, pfx = "\(bottlesDir)/\(b)"; busy = true
        Task { @MainActor in
            let ws = "env WINEPREFIX='\(pfx)' '\((wineBin as NSString).deletingLastPathComponent)/wineserver'"
            _ = await Task.detached { shell("\(ws) -k 2>/dev/null; perl -e 'alarm 15; exec @ARGV' -- sh -c \"\(ws) -w\" 2>/dev/null") }.value
            let f = DateFormatter(); f.dateFormat = Model.snapStamp
            let aside = "\(bottlesDir)/.auto-\(b)-\(f.string(from: Date()))"
            var err = ""
            if rename(pfx, aside) != 0 { err = String(cString: strerror(errno)) }
            else if clonefile(snap, pfx, UInt32(CLONE_NOFOLLOW)) != 0 { err = String(cString: strerror(errno)); _ = rename(aside, pfx) }   // put it back
            if err.isEmpty {
                try? "state before rollback".write(toFile: aside + "/.snapshot-reason", atomically: false, encoding: .utf8)
                try? FileManager.default.removeItem(atPath: pfx + "/.snapshot-reason")
                Model.pruneSnapshots(b)
                log += "Rolled back \(b) to \((snap as NSString).lastPathComponent); the state before is kept as snapshot \((aside as NSString).lastPathComponent).\n"
            } else { log += "Rollback of \(b) failed (\(err)); the bottle is unchanged.\n" }
            busy = false; refresh()
        }
    }
}
