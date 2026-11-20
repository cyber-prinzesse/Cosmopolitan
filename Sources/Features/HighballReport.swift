import SwiftUI

extension Model {
    // §7.9 Contribute back (opt-in, by click): a pre-filled Highball issue with chip, macOS, engine and driver set — no personal data, no library.
    func reportURL(_ exe: String) -> URL? {
        let g = steamGames[exe], chip = sh("sysctl -n machdep.cpu.brand_string"), ram = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let title = "Report: \(appName(exe))\(g.map { " (\($0.id))" } ?? "") on \(chip)"
        let body = """
        **Game:** \(appName(exe))\(g.map { " — Steam app id \($0.id)" } ?? "")
        **Mac:** \(chip), \(ram) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        **Launcher:** Cosmopolitan \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"), engine \(sh("\(shq("\(wineBin)")) --version 2>/dev/null"))
        **Backend:** \(driverList(launchEnvRaw(), bottle: selected).joined(separator: " + "))\(readiness[exe]?.drivers.map { " (this game: \($0.joined(separator: " + ")))" } ?? "")
        \(fallbackNote(exe).map { "**Driver fallback:** \($0)\n" } ?? "")**Result:** <works / works with issues / does not start — please fill in>
        **Notes:** <fps, settings, crashes>
        """
        var c = URLComponents(string: "https://github.com/gauthierpiarrette/highball-db/issues/new")!
        c.queryItems = [.init(name: "title", value: title), .init(name: "body", value: body), .init(name: "labels", value: "report")]
        return c.url
    }
    // Opens the prefilled GitHub form in the browser. That is all: GitHub sends nothing until the user presses Submit there.
    func reportToHighball(_ exe: String) {
        if let u = reportURL(exe) { NSWorkspace.shared.open(u); log += "Opened a pre-filled Highball report for \(appName(exe)) in the browser; nothing is sent until you submit it.\n" }
    }

    // Opt-in (Settings › Compatibility reports): after a session of 5+ minutes, offer the prefilled report once per game.
    nonisolated static func shouldOfferReport(enabled: Bool, seconds: TimeInterval, alreadyOffered: Bool) -> Bool { enabled && seconds >= 300 && !alreadyOffered }
    func reportMark(_ exe: String) -> String { "\(bottlesDir)/\(selected)/options/.reported-\((exe as NSString).lastPathComponent)" }
    // End of a session. `ask` shows the question (an alert in the app, a printed line on the command line); `open` hands the prefilled
    // form to the browser. No network request is made here: the report only exists on GitHub if the user submits the form.
    @discardableResult func sessionEnded(_ exe: String, seconds: TimeInterval, ask: (String) -> Bool, open: (URL) -> Void) -> String {
        let enabled = UserDefaults.standard.bool(forKey: "compatReports"), mark = reportMark(exe)
        guard Model.shouldOfferReport(enabled: enabled, seconds: seconds, alreadyOffered: FileManager.default.fileExists(atPath: mark)) else {
            return "no offer (reports \(enabled ? "on" : "off"), session \(Int(seconds)) s)"
        }
        try? FileManager.default.createDirectory(atPath: (mark as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mark, contents: nil)
        guard ask("How did \(appName(exe)) run? Cosmopolitan can open a prefilled compatibility report for the Highball database. You review and submit it on GitHub; nothing is sent otherwise."), let u = reportURL(exe) else { return "offered, declined" }
        open(u); return "offered, prefilled report opened (not submitted)"
    }
    func offerReportAfterSession(_ exe: String) {
        guard UserDefaults.standard.bool(forKey: "compatReports"), !FileManager.default.fileExists(atPath: reportMark(exe)) else { return }
        let started = Date()
        whenExits(exe) {
            self.sessionEnded(exe, seconds: Date().timeIntervalSince(started), ask: { text in
                let a = NSAlert(); a.messageText = "How did \(appName(exe)) run?"; a.informativeText = text
                a.addButton(withTitle: "Open report"); a.addButton(withTitle: "Not now"); return a.runModal() == .alertFirstButtonReturn
            }, open: { NSWorkspace.shared.open($0); self.log += "Opened a pre-filled Highball report for \(appName(exe)); nothing is sent until you submit it.\n" })
        }
    }
}
