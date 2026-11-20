import SwiftUI

extension Model {
    // §7.1 "Will it run?" — a verdict for THIS Mac from Highball + ProtonDB + the anti-cheat map, before buying.
    func willItRun(_ link: String) -> String {
        guard let id = link.components(separatedBy: "/app/").dropFirst().first?.components(separatedBy: "/").first ?? (Int(link) != nil ? link : nil) else { return "Paste a Steam store link (…/app/<id>/…) or an app id.\n" }
        let c = communityFixes(id)
        let hb = sh("curl -s -m 8 \(shq("https://gethighball.com/data/steam/\(id).json"))")
        let title = hb.components(separatedBy: "\"title\": \"").dropFirst().first?.components(separatedBy: "\"").first ?? "App \(id)"
        var v = "Will it run? \(title) on \(sh("sysctl -n machdep.cpu.brand_string")), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString):\n"
        if let ac = antiCheatVerdict(c.anticheat) { v += "  • \(ac.1)\n" }
        if c.hbStatus == "blocked-anticheat" || antiCheatVerdict(c.anticheat)?.0 == .red { return v + "  → No. Kernel anti-cheat cannot run under any Wine on a Mac; consider cloud gaming or a native Mac version.\n" }
        if !c.hbStatus.isEmpty { v += "  • Highball: \(c.hbStatus)\(c.renderer.isEmpty ? "" : ", runs through \(c.renderer)")\n" }
        if !c.tier.isEmpty { v += "  • ProtonDB (Linux, indicative): \(c.tier)\n" }
        if c.renderer == "d3dmetal" { v += d3dmetalOK ? "  • Needs Direct3D 12 → D3DMetal (accepted) ✓\n" : "  • Needs Direct3D 12 → D3DMetal: install from Apple and accept its license first\n" }
        let good = ["verified-local", "reported-upstream", "community"].contains(c.hbStatus) || ["platinum", "gold"].contains(where: { c.tier.hasPrefix($0) })
        v += good ? "  → Likely yes" : (c.hbStatus.isEmpty && c.tier.isEmpty ? "  → Unknown: no reports yet; the launch check will tell once installed" : "  → Doubtful: weak reports")
        return v + (c.anticheat.isEmpty ? "" : " (offline/single-player)") + ".\n"
    }
}
