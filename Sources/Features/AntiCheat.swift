import SwiftUI
#if canImport(CosmoNative)
import CosmoNative   // swift build: the C++ module is a package target (scripts/build.sh uses the bridging header)
#endif

extension Model {
    // Anti-cheat detection. Signatures checked against real installs (Dawnwalker ships EOSSDK without EAC — EOS alone is NOT anti-cheat).
    func antiCheatSignatures(in folder: String) -> [String] {
        var found: [String] = []
        guard let en = FileManager.default.enumerator(atPath: folder) else { return found }
        for case let p as String in en {
            if en.level > 4 { en.skipDescendants(); continue }
            let n = (p as NSString).lastPathComponent.lowercased()
            if n == "easyanticheat" || n.hasPrefix("easyanticheat_") || n == "easyanticheat_eos_setup.exe" { found.append("Easy Anti-Cheat") }
            else if n == "battleye" || n.hasPrefix("beservice") || n.hasPrefix("beclient") { found.append("BattlEye") }
            else if n == "vgc.exe" || n == "vgk.sys" { found.append("Vanguard") }
            else if n.contains("ricochet") && n.hasSuffix(".sys") { found.append("RICOCHET") }
            else if n == "nprotect" || n.hasPrefix("gameguard") { found.append("nProtect GameGuard") }
            else if n.hasPrefix("xigncode") { found.append("XIGNCODE3") }
            else if n == "mhyprot2.sys" || n == "mhyprot3.sys" { found.append("mhyprot") }
        }
        return Array(Set(found)).sorted()
    }
    // Honest badge, decided by the decision engine (cosmo_anticheat, item 29) from what was found and AreWeAntiCheatYet's status.
    static let kernelAC = ["Vanguard", "RICOCHET", "FACEIT", "nProtect GameGuard", "XIGNCODE3", "mhyprot", "Javelin", "Denuvo Anti-Cheat", "EQU8", "Wellbia"]
    func antiCheatVerdict(_ names: [String], appid: String? = nil, name: String? = nil) -> (Color, String)? {
        let aw = Model.awacy(steam: appid, name: name)
        let all = names + (aw?.anticheats ?? [])
        var found: UInt32 = 0
        for n in all {
            if Model.kernelAC.contains(where: { n.localizedCaseInsensitiveContains($0) }) || n.localizedCaseInsensitiveContains("kernel") { found |= UInt32(COSMO_AC_KERNEL) }
            if n.localizedCaseInsensitiveContains("Easy Anti-Cheat") || n.localizedCaseInsensitiveContains("EasyAntiCheat") { found |= UInt32(COSMO_AC_EAC) }
            if n.localizedCaseInsensitiveContains("BattlEye") { found |= UInt32(COSMO_AC_BATTLEYE) }
        }
        let r = cosmo_anticheat(found, Int32(aw?.status.rawValue ?? 0)), list = Array(Set(all)).sorted().joined(separator: ", ")
        switch r.reason {
        case Int32(COSMO_ACR_KERNEL.rawValue): return (.red, "Kernel anti-cheat (\(list)): will not run; use cloud gaming or a native Mac version")
        case Int32(COSMO_ACR_DENIED.rawValue): return (.red, "Anti-cheat (\(list)): the developer blocks Wine/Proton (AreWeAntiCheatYet: Denied)")
        case Int32(COSMO_ACR_BROKEN.rawValue): return (.red, "Anti-cheat (\(list)): doesn't work under Wine/Proton (AreWeAntiCheatYet: Broken)")
        case Int32(COSMO_ACR_ONLINE.rawValue): return (.yellow, "Online won't work (\(list.isEmpty ? "anti-cheat" : list)); offline/single-player usually fine" + (aw.map { " (AreWeAntiCheatYet: \($0.label) on Linux)" } ?? ""))
        default: return nil
        }
    }
    // AreWeAntiCheatYet (MIT, github.com/AreWeAntiCheatYet): its games.json is fetched at runtime into the cache, at most once a day, and
    // never bundled. Looked up by Steam app id, else by name. The test build can point the download elsewhere (COSMO_TEST_URL_awacy).
    nonisolated static var awacyPath: String { support + "/cache/awacy-games.json" }
    nonisolated static func refreshAwacy(force: Bool = false) -> String {
        let p = awacyPath, fm = FileManager.default
        if !force, let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 86400 { return "AreWeAntiCheatYet list is current." }
        let url = (isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_URL_awacy"] : nil) ?? "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json"
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = shell("curl -fsSL --max-time 60 -o \(shq("\(p).part")) \(shq("\(url)")) && mv \(shq("\(p).part")) \(shq("\(p)"))")
        awacyLock.lock(); awacyIndex = nil; awacyLock.unlock()
        return fm.fileExists(atPath: p) ? "AreWeAntiCheatYet list: \(awacyCount()) games." : "AreWeAntiCheatYet list could not be downloaded."
    }
    struct AwacyEntry: Sendable { let status: cosmo_awacy; let label: String; let anticheats: [String] }
    nonisolated(unsafe) private static var awacyIndex: (bySteam: [String: AwacyEntry], byName: [String: AwacyEntry])? = nil
    nonisolated private static let awacyLock = NSLock()
    nonisolated static func awacyCount() -> Int { loadAwacy().bySteam.count + loadAwacy().byName.count }
    nonisolated private static func loadAwacy() -> (bySteam: [String: AwacyEntry], byName: [String: AwacyEntry]) {
        awacyLock.lock(); defer { awacyLock.unlock() }
        if let i = awacyIndex { return i }
        var bySteam: [String: AwacyEntry] = [:], byName: [String: AwacyEntry] = [:]
        if let d = FileManager.default.contents(atPath: awacyPath), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            let statuses: [String: cosmo_awacy] = ["Supported": COSMO_AWACY_SUPPORTED, "Running": COSMO_AWACY_RUNNING, "Planned": COSMO_AWACY_PLANNED, "Broken": COSMO_AWACY_BROKEN, "Denied": COSMO_AWACY_DENIED]
            for g in arr {
                let label = g["status"] as? String ?? "", e = AwacyEntry(status: statuses[label] ?? COSMO_AWACY_UNKNOWN, label: label, anticheats: g["anticheats"] as? [String] ?? [])
                if let id = (g["storeIds"] as? [String: Any])?["steam"] { bySteam["\(id)"] = e }
                else if let n = g["name"] as? String { byName[normName(n)] = e }
            }
        }
        awacyIndex = (bySteam, byName); return awacyIndex!
    }
    nonisolated static func normName(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    nonisolated static func awacy(steam: String?, name: String?) -> AwacyEntry? {
        let i = loadAwacy()
        if let s = steam, let e = i.bySteam[s] { return e }
        if let n = name, !n.isEmpty { return i.byName[normName(n)] }
        return nil
    }
}
