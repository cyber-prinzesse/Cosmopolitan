import SwiftUI

extension Model {
    // Community knowledge per Steam AppID, cached 7 days in <bottle>/fixes: ProtonDB tier (expectation), umu-protonfixes (known fixes;
    // calls that translate to plain Wine: protontricks, winedll_override, set_environment, append_argument) and Highball (CC0: curated
    // renderer per title, anti-cheat map, launch args). Highball's status values: verified-local, reported-upstream, community, blocked-anticheat.
    func communityFixes(_ appid: String) -> (tier: String, verbs: [String], overrides: [(String, String)], env: [String: String], args: [String], renderer: String, hbStatus: String, anticheat: [String], launchArgs: String) {
        let dir = "\(bottlesDir)/\(selected)/fixes", fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func cached(_ name: String, _ url: String) -> String {
            let p = "\(dir)/\(name)"
            if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 7 * 86400 { return (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
            _ = sh("curl -s -m 6 -o \(shq("\(p)")) -w '%{http_code}' \(shq("\(url)")) | grep -q '^200$' || : > \(shq("\(p)"))")   // 404 = no fix needed; empty file remembers that
            return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
        }
        let db = cached("\(appid).json", "https://www.protondb.com/api/v1/reports/summaries/\(appid).json")
        let tier = db.components(separatedBy: "\"tier\": \"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
        let total = db.components(separatedBy: "\"total\": ").dropFirst().first?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fix = cached("\(appid).py", "https://raw.githubusercontent.com/Open-Wine-Components/umu-protonfixes/master/gamefixes-steam/\(appid).py")
        func calls(_ fn: String) -> [[String]] {   // util.fn('a', 'b') -> ["a", "b"]
            let re = try! NSRegularExpression(pattern: "util\\.\(fn)\\(([^)]*)\\)")
            return re.matches(in: fix, range: NSRange(fix.startIndex..., in: fix)).map { m in
                String(fix[Range(m.range(at: 1), in: fix)!]).split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } }
        }
        let modes = ["n": "native", "b": "builtin", "n,b": "native,builtin", "b,n": "builtin,native", "": ""]
        let overrides = calls("winedll_override").filter { $0.count >= 2 }.compactMap { c in modes[c.dropFirst().joined(separator: ",")].map { (c[0], $0) } }
        var env: [String: String] = [:]
        for c in calls("set_environment") where c.count == 2 && !c[0].hasPrefix("PROTON_") && !c[0].hasPrefix("DXVK_") { env[c[0]] = c[1] }
        // Highball: gethighball.com/data/steam/<appid>.json (404 = unknown title, cached as empty)
        let hb = cached("\(appid).highball.json", "https://gethighball.com/data/steam/\(appid).json")
        func field(_ k: String, in t: String) -> String { t.components(separatedBy: "\"\(k)\": \"").dropFirst().first?.components(separatedBy: "\"").first ?? "" }
        let game = hb.components(separatedBy: "\"game\": {").dropFirst().first ?? ""
        let renderer = field("renderer", in: game).lowercased(), hbStatus = field("status", in: game), launchArgs = field("launchArgs", in: game)
        var ac: [String] = []
        if let a = game.components(separatedBy: "\"anticheat\": {").dropFirst().first?.components(separatedBy: "}").first, let list = a.components(separatedBy: "\"anticheats\": [").dropFirst().first?.components(separatedBy: "]").first {
            ac = list.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
        }
        if hbStatus == "blocked-anticheat", ac.isEmpty { ac = ["kernel anti-cheat (Highball blocklist)"] }
        return (tier.isEmpty ? "" : "\(tier) (\(total) reports)", calls("protontricks").compactMap { $0.first }, overrides, env, calls("append_argument").compactMap { $0.first }, renderer, hbStatus, ac, launchArgs)
    }
}
