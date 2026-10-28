import SwiftUI

extension Model {
    // Steam's window loop (seen 2026-10-28 on an 8 GB Mac deep in swap): steam.exe stays up, but its window process, steamwebhelper, dies
    // and Steam starts it again every 13–21 s, so the window keeps closing and reopening. Steam logs each start in logs/webhelper.txt; three
    // within 2 minutes is a loop (a normal start plus the restart at sign-in make two). Checked every 30 s with the memory advisor.
    nonisolated static func webhelperStarts(_ text: String, within window: TimeInterval, now: Date = Date()) -> [Date] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"   // Wine logs local time
        return text.components(separatedBy: "\n").compactMap { l in
            guard l.hasPrefix("["), l.contains("] Startup - webhelper launched"), let e = l.firstIndex(of: "]"),
                  let d = f.date(from: String(l[l.index(after: l.startIndex)..<e])), now.timeIntervalSince(d) <= window else { return nil }
            return d
        }
    }
    // Said once per loop (then quiet for 10 min per bottle): a warning with the memory state, a crash record with webhelper.txt's tail
    // for the bug report, and, for the selected bottle's running Steam, the offer to restart it. `force`: no rate limit (--steamloop).
    func steamLoopCheck(force: Bool = false) {
        for b in bottles {
            let dir = "\(bottlesDir)/\(b)/drive_c/Program Files (x86)/Steam", path = dir + "/logs/webhelper.txt"
            guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 120,
                  force || Date().timeIntervalSince(steamLoopWarned[b] ?? .distantPast) > 600, let h = FileHandle(forReadingAtPath: path) else { continue }
            let end = h.seekToEndOfFile(); h.seek(toFileOffset: end > 65536 ? end - 65536 : 0)   // the log grows all session; the tail is enough
            let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self); h.closeFile()
            let starts = Model.webhelperStarts(tail, within: 120)
            guard starts.count >= 3 else { continue }
            steamLoopWarned[b] = Date()
            let (level, swap) = memoryState(), low = level < 20 || swap > 4096
            let what = "Steam's window restarted \(starts.count) times in 2 min"
            log += "⚠ \(what) (\(b)): its web helper keeps dying and Steam starts it again. Free memory \(level)%, swap \(Int(swap)) MB. "
                + (low ? "The Mac is short of memory, the likeliest cause: quit other apps (browsers, virtual machines), then restart Steam.\n" : "If it goes on, restart Steam.\n")
            captureCrash(dir + "/steam.exe", 0, headline: what, tail: ("Last lines of Steam's logs/webhelper.txt", tail.components(separatedBy: "\n").suffix(80).joined(separator: "\n")))
            if b == selected, steamRunning(in: b),
               ask("Restart Steam?", "\(what): it keeps closing and reopening." + (low ? " The Mac is short of memory; quit other apps first, or it may start again." : ""), yes: "Restart Steam") {
                restartSteam(b, because: "its window stops restarting")
            }
        }
    }
}
