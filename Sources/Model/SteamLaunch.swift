import SwiftUI

extension Model {
    func launchCmd(_ exe: String) -> (String, [String]) {
        if let g = steamGames[exe], let r = exe.range(of: "/steamapps/") {
            let steam = String(exe[..<r.lowerBound]) + "/steam.exe"
            return (winPath(steam), extraArgs(steam) + ["-applaunch", g.id])
        }
        // Ubisoft Connect on a Wine 11 engine: its window stays blank unless Chromium draws inside upc.exe itself (in-process, in
        // software); the UbisoftConnect.exe stub doesn't pass switches on, so start upc.exe the way the stub does, plus the switches.
        if engineIsWine11(), let upc = ubisoftClient(exe) { return (winPath(upc), ["-upc_desktop_mode"] + Model.ubisoftCEFSwitches + extraArgs(exe)) }
        return (winPath(exe), extraArgs(exe))
    }

    // Item 3: measured on r29 — default start: blank window; with these: the login page (as on CrossOver). Wine 10 stays blank either way.
    static let ubisoftCEFSwitches = ["--no-sandbox", "--in-process-gpu", "--disable-gpu"]
    func ubisoftClient(_ exe: String) -> String? {
        guard ["ubisoftconnect.exe", "upc.exe"].contains((exe as NSString).lastPathComponent.lowercased()) else { return nil }
        let upc = (exe as NSString).deletingLastPathComponent + "/upc.exe"
        return FileManager.default.fileExists(atPath: upc) ? upc : nil
    }
}
