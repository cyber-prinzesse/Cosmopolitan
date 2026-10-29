import SwiftUI

// Item 27: a game that crashes within 30 s gets one retry with the next driver (DXMT → D3DMetal → DXVK), chosen by the decision engine's
// row 12 (cosmo_fallback, C++). The working driver is remembered in the game's Options (a DRIVERS= line marked as the fallback's) and goes
// into compatibility reports; a retry that crashes too puts the game back to automatic. The user's own DRIVERS choice is asked about.
extension Model {
    nonisolated static let fallbackMark = "# driver fallback:"
    static let chainSets: [(name: String, backend: cosmo_backend, set: [String])] = [("dxmt", COSMO_BE_DXMT, ["dxmt", "d9vk", "cnc_ddraw"]),
        ("d3dmetal", COSMO_BE_D3DMETAL, ["d3dmetal", "d9vk", "cnc_ddraw"]), ("dxvk", COSMO_BE_DXVK, ["dxvk", "cnc_ddraw"])]
    static let apiBits: [String: UInt32] = ["Direct3D 12": UInt32(COSMO_API_D3D12), "Direct3D 11": UInt32(COSMO_API_D3D11),
        "Direct3D 10": UInt32(COSMO_API_D3D10), "Direct3D 9": UInt32(COSMO_API_D3D9), "Direct3D 8": UInt32(COSMO_API_D3D8),
        "DirectDraw": UInt32(COSMO_API_DDRAW)]

    // Called when a program exits non-zero within 30 s of starting. True when a retry was started (no triage then).
    func driverFallback(_ exe: String, _ code: Int32) -> Bool {
        // Steam hosts every game's CreateProcess: pinning steam.exe to DXVK/DXMT leaves DX12 games without D3DMetal
        // ("Support for DirectX 12 is missing"). Exit 42 (self-update) is already ignored; refuse all Steam fallbacks.
        if exe.lowercased().hasSuffix("/steam/steam.exe") { return false }
        let name = appName(exe), opts = (try? String(contentsOfFile: optionsPath(exe), encoding: .utf8)) ?? ""
        let used = launchedDrivers[exe] ?? []
        guard let crashed = Model.chainSets.first(where: { used.contains($0.name) }) else { return false }   // not on a driver of the chain
        if fallbackTried.contains(exe) {   // the one retry crashed too: back to automatic
            fallbackTried.remove(exe)
            if opts.contains(Model.fallbackMark) { saveOptions(exe, Model.withoutFallback(opts)) }
            log += "\(name) crashed with \(crashed.name) too; it is back to the automatic driver choice.\n"; return false
        }
        var inp = cosmo_decision_input()
        let apis = driverPlan(exe, imports: exeImports(exe)).apis
        inp.apis = apis.reduce(0) { $0 | (Model.apiBits[$1] ?? 0) }
        let failed = Set(Model.fallbackHistory(opts).map(\.crashed) + [crashed.name])
        let installed = Set(installedDrivers())
        withUnsafeMutableBytes(of: &inp.serves) { buf in
            let s = buf.bindMemory(to: UInt32.self)
            if installed.contains("dxmt") { s[Int(COSMO_BE_DXMT.rawValue)] = UInt32(COSMO_API_D3D10 | COSMO_API_D3D11) }
            if installed.contains("d3dmetal"), d3dmetalOK, d3dmetalInstalled() { s[Int(COSMO_BE_D3DMETAL.rawValue)] = UInt32(COSMO_API_D3D11 | COSMO_API_D3D12) }
            if installed.contains("dxvk"), driverUsable("dxvk") { s[Int(COSMO_BE_DXVK.rawValue)] = UInt32(COSMO_API_D3D9 | COSMO_API_D3D10 | COSMO_API_D3D11) }
        }
        withUnsafeMutableBytes(of: &inp.failed_here) { buf in
            let f = buf.bindMemory(to: UInt8.self)
            for c in Model.chainSets where failed.contains(c.name) { f[Int(c.backend.rawValue)] = 1 }
        }
        let userPin = options(exe)["DRIVERS"] != nil && !opts.contains(Model.fallbackMark)
        if userPin { inp.game_pin = Int32(crashed.backend.rawValue) }
        let d = cosmo_fallback(&inp, Int32(crashed.backend.rawValue))
        guard d.error == 0, d.verdict == Int32(COSMO_USE.rawValue) || d.verdict == Int32(COSMO_ASK.rawValue),
              let next = Model.chainSets.first(where: { Int32($0.backend.rawValue) == d.backend }) else {
            log += "\(name) crashed within 30 s with \(crashed.name); no other driver can run it here.\n"; return false
        }
        if d.verdict == Int32(COSMO_ASK.rawValue),   // the user chose this driver themselves: their call
           !ask("Try \(name) with \(next.name)?", "It crashed right away with \(crashed.name), the driver set in its Options.", yes: "Try \(next.name)") { return false }
        snapshot("before driver switch: \(name) → \(next.name) (driver fallback)"); backupSaves(exe, "before driver switch")
        let history = Model.fallbackHistory(opts).map { "\($0.crashed)@\($0.when)" } + ["\(crashed.name)@\(Model.stamp())"]
        saveOptions(exe, Model.withoutFallback(opts) + "\n\(Model.fallbackMark) \(history.joined(separator: " ")) crashed; using \(next.name)\nDRIVERS=\(next.set.joined(separator: ","))\n")
        fallbackTried.insert(exe); launchExits[exe] = nil   // a CLI --wait keeps waiting for the retry
        log += "\(name) crashed within 30 s with \(crashed.name) (exit \(code)); trying \(next.name) once. It is remembered if it works.\n"
        launch(exe)
        return true
    }
    // steam.exe must not keep a driver-fallback DRIVERS= pin: every Steam Play game inherits that Unix env (WINEDLLPATH_*).
    func clearSteamHostDriverFallback(_ exe: String) {
        let path = optionsPath(exe)
        let opts = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard opts.contains(Model.fallbackMark) else { return }
        let cleaned = Model.withoutFallback(opts)
        if cleaned != opts.trimmingCharacters(in: .newlines) {
            saveOptions(exe, cleaned.isEmpty ? "" : cleaned + "\n")
            log += "Steam: removed a driver-fallback pin from its Options (games started from Steam need this bottle's drivers, not a pinned DXVK/DXMT set).\n"
        }
    }

    // Options text without the fallback's lines (its marker and the DRIVERS line right after it).
    nonisolated static func withoutFallback(_ t: String) -> String {
        var out: [String] = [], skip = false
        for l in t.components(separatedBy: "\n") {
            if l.hasPrefix(fallbackMark) { skip = true; continue }
            if skip, l.hasPrefix("DRIVERS=") { skip = false; continue }
            skip = false; out.append(l)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
    // The drivers that crashed this game before, from its Options ("# driver fallback: dxmt@2026-10-23 crashed; using d3dmetal").
    nonisolated static func fallbackHistory(_ t: String) -> [(crashed: String, when: String)] {
        guard let l = t.components(separatedBy: "\n").first(where: { $0.hasPrefix(fallbackMark) }) else { return [] }
        return l.dropFirst(fallbackMark.count).components(separatedBy: " ").compactMap { w in
            let p = w.split(separator: "@"); return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }
    }
    nonisolated static func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }
    // For compatibility reports: what the fallback learned about this game.
    func fallbackNote(_ exe: String) -> String? {
        let t = (try? String(contentsOfFile: optionsPath(exe), encoding: .utf8)) ?? ""
        guard let l = t.components(separatedBy: "\n").first(where: { $0.hasPrefix(Model.fallbackMark) }) else { return nil }
        return String(l.dropFirst(Model.fallbackMark.count)).trimmingCharacters(in: .whitespaces)
    }
}
