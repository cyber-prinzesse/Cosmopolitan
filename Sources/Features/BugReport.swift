import SwiftUI

extension Model {
    // §8.12 Bug report: everything a maintainer needs, with the username and home folder stripped. The newest crash record (item 34: for
    // the game the report is about, when there is one) is attached automatically.
    func bugReportText(for exe: String? = nil) -> String {
        let home = NSHomeDirectory(), user = NSUserName()
        var r = "## Cosmopolitan bug report\n"
        r += "- App: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))\n"
        r += "- Mac: \(sh("sysctl -n machdep.cpu.brand_string")), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        r += "- Engine: \(sh("'\(wineBin)' --version 2>/dev/null")); drivers: \(driverList(launchEnvRaw(), bottle: selected).joined(separator: "+")); D3DMetal accepted: \(d3dmetalOK)\n"
        r += "- Bottle: \(selected); programs: \(programs.map { appName($0) + " [" + (readiness[$0]?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") + "]" }.joined(separator: "; "))\n"
        r += "- Status: \(driverStatus.1) / \(padStatus.1)\n\n### Log (last 200 lines)\n```\n"
        r += log.components(separatedBy: "\n").suffix(200).joined(separator: "\n") + "\n```\n"
        if let c = latestCrash(for: exe) { r += "\n### Last crash\n```\n" + c + "```\n" }
        return r.replacingOccurrences(of: home, with: "~").replacingOccurrences(of: user, with: "<user>")
    }
    func copyBugReport(for exe: String? = nil) {
        let r = bugReportText(for: exe)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r, forType: .string)
        log += "Bug report copied to the clipboard (paths and username removed). Paste it into a GitHub issue.\n"
    }
    // Item 34: a program that exits with an error leaves a crash record in support/crash-reports: the last log lines, the driver set it ran
    // with and the versions of everything involved. The newest 20 are kept.
    // `headline`/`tail`: a record of something other than an exit (Steam's window loop), with its own log lines instead of the app's.
    func captureCrash(_ exe: String, _ code: Int32, headline: String? = nil, tail own: (label: String, text: String)? = nil) {
        let fm = FileManager.default, dir = support + "/crash-reports", b = bottleOf(exe), f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tail = own?.text ?? ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").components(separatedBy: "\n").suffix(80).joined(separator: "\n")
        var r = "\(headline ?? "\(appName(exe)) exited with code \(code)") at \(Date())\n"
        r += "Program: \(exe)\nBottle: \(b)\nDrivers: \((launchedDrivers[exe] ?? driverList(launchEnvRaw(b), bottle: b)).joined(separator: "+"))\n"
        r += "Versions: Cosmopolitan \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")) · engine \(shell("'\(wineBin)' --version 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines))"
        r += " · D3DMetal \(d3dmetalNow?.pretty ?? "not installed") · \(installedDrivers().map(driverLabel).joined(separator: ", ")) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        r += "\(own?.label ?? "Last log lines"):\n\(tail)\n"
        let name = appName(exe).replacingOccurrences(of: "/", with: "-")
        try? r.write(toFile: "\(dir)/\(name) \(f.string(from: Date())).txt", atomically: true, encoding: .utf8)
        for old in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted { (try? fm.attributesOfItem(atPath: "\(dir)/\($0)"))?[.modificationDate] as? Date ?? .distantPast > (try? fm.attributesOfItem(atPath: "\(dir)/\($1)"))?[.modificationDate] as? Date ?? .distantPast }.dropFirst(20) {
            try? fm.removeItem(atPath: "\(dir)/\(old)")
        }
    }
    func latestCrash(for exe: String?) -> String? {
        let dir = support + "/crash-reports", fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { f in exe.map { f.hasPrefix(appName($0).replacingOccurrences(of: "/", with: "-") + " ") } ?? true }
        guard let newest = files.max(by: { ((try? fm.attributesOfItem(atPath: "\(dir)/\($0)"))?[.modificationDate] as? Date ?? .distantPast) < ((try? fm.attributesOfItem(atPath: "\(dir)/\($1)"))?[.modificationDate] as? Date ?? .distantPast) }) else { return nil }
        return try? String(contentsOfFile: "\(dir)/\(newest)", encoding: .utf8)
    }
}
