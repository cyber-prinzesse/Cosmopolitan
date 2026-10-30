import Foundation

// Every registry value Cosmopolitan writes into a bottle is recorded in options/.registry-ledger.json, so it can be removed again when the
// setting that wanted it is gone. "launch" values (Windows version, virtual desktop, Retina off, mouse capture, community DLL overrides)
// follow the program's current launch check; "bottle" values (Steam's tweaks, DPI, the shared desktop size) stay. A value someone changed
// after we wrote it is never removed, only forgotten.
struct RegEntry: Codable, Hashable, Sendable { let key: String; let name: String; let value: String; let exe: String; let owner: String }

func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }   // safe in a /bin/sh command

extension Model {
    nonisolated static func ledgerPath(_ bottle: String) -> String { "\(bottlesDir)/\(bottle)/options/.registry-ledger.json" }
    nonisolated static func ledger(_ bottle: String) -> [RegEntry] {
        (try? JSONDecoder().decode([RegEntry].self, from: Data(contentsOf: URL(fileURLWithPath: ledgerPath(bottle))))) ?? []
    }
    nonisolated static func saveLedger(_ bottle: String, _ l: [RegEntry]) {
        try? FileManager.default.createDirectory(atPath: "\(bottlesDir)/\(bottle)/options", withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(l).write(to: URL(fileURLWithPath: ledgerPath(bottle)), options: .atomic)
    }
    // Writes a value and records it.
    nonisolated static func regSet(_ bottle: String, _ key: String, _ name: String, _ value: String, type: String = "REG_SZ", exe: String, owner: String) {
        _ = shell("\(plainWine("\(bottlesDir)/\(bottle)")) reg add \(shq(key)) /v \(shq(name)) /t \(type) /d \(shq(value)) /f >/dev/null 2>&1")
        var l = ledger(bottle).filter { !($0.key == key && $0.name == name) }
        l.append(RegEntry(key: key, name: name, value: value, exe: exe, owner: owner)); saveLedger(bottle, l)
    }
    // Removes a value (and drops it from the ledger). Used when a template left a bottle setting that breaks Steam (Systray Hidden).
    nonisolated static func regDelete(_ bottle: String, _ key: String, _ name: String) {
        _ = shell("\(plainWine("\(bottlesDir)/\(bottle)")) reg delete \(shq(key)) /v \(shq(name)) /f >/dev/null 2>&1")
        saveLedger(bottle, ledger(bottle).filter { !($0.key == key && $0.name == name) })
    }
    // Every Steam start: one `wine reg` call costs ~1.5 s (6.7 s cold), and steamBottleTweaks makes 17, so only the tray value is
    // healed here, in Steam's own bottle, and only when user.reg (read as text, no Wine) still has it. After that it's free.
    nonisolated static func healSteamSystray(_ bottle: String) {
        let reg = (try? String(contentsOfFile: "\(bottlesDir)/\(bottle)/user.reg", encoding: .utf8)) ?? ""
        guard let r = reg.range(of: "[Software\\\\Wine\\\\Systray]") else { return }
        let section = reg[r.upperBound...].components(separatedBy: "\n\n").first ?? ""
        guard section.contains("\"Hidden\"=dword:00000001") else { return }
        regDelete(bottle, "HKCU\\Software\\Wine\\Systray", "Hidden")
    }
    // Current value from the bottle's live registry (nil = not set).
    nonisolated static func regGet(_ bottle: String, _ key: String, _ name: String) -> String? {
        let out = shell("\(plainWine("\(bottlesDir)/\(bottle)")) reg query \(shq(key)) /v \(shq(name)) 2>/dev/null | tr -d '\\r'")
        for line in out.components(separatedBy: "\n") {
            let f = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "    ").filter { !$0.isEmpty }
            if f.count >= 2, f[0] == name, f[1].hasPrefix("REG_") { return f.count >= 3 ? f[2] : "" }
        }
        return nil
    }
    // Removes the recorded "launch" values of `exe` that `wanted` ("key|name") doesn't contain. Returns what was removed.
    @discardableResult nonisolated static func pruneRegistry(_ bottle: String, exe: String, wanted: Set<String>) -> [String] {
        var l = ledger(bottle), removed: [String] = []
        for e in l where e.owner == "launch" && e.exe.caseInsensitiveCompare(exe) == .orderedSame && !wanted.contains(e.key + "|" + e.name) {
            if regGet(bottle, e.key, e.name) == e.value {
                _ = shell("\(plainWine("\(bottlesDir)/\(bottle)")) reg delete \(shq(e.key)) /v \(shq(e.name)) /f >/dev/null 2>&1")
                removed.append("\(e.key)\\\(e.name) (was \"\(e.value)\")")
            }
            l.removeAll { $0 == e }
        }
        saveLedger(bottle, l); return removed
    }
    // Values written before the ledger existed: an AppDefaults\<exe> set carrying our signature, Explorer\Desktop = "Cosmopolitan", plus its
    // Version and Mac Driver\RetinaMode values. Read from user.reg (old values are long since flushed to disk).
    nonisolated static func adoptLegacyRegistry(_ bottle: String) {
        let reg = (try? String(contentsOfFile: "\(bottlesDir)/\(bottle)/user.reg", encoding: .utf8)) ?? ""
        var sections: [String: String] = [:]   // section path (single backslashes) → body
        for chunk in reg.components(separatedBy: "\n[").dropFirst() {
            guard let end = chunk.firstIndex(of: "]") else { continue }
            sections[String(chunk[..<end]).replacingOccurrences(of: "\\\\", with: "\\")] = String(chunk[end...])
        }
        let pre = "Software\\Wine\\AppDefaults\\"
        func value(_ section: String, _ name: String) -> String? {
            guard let body = sections[section], let r = body.range(of: "\"\(name)\"=\"") else { return nil }
            return body[r.upperBound...].components(separatedBy: "\"").first
        }
        var l = ledger(bottle)
        func adopt(_ key: String, _ name: String, _ v: String, _ exe: String) {
            if !l.contains(where: { $0.key == "HKCU\\" + key && $0.name == name }) { l.append(RegEntry(key: "HKCU\\" + key, name: name, value: v, exe: exe, owner: "launch")) }
        }
        for (s, _) in sections where s.hasPrefix(pre) && s.hasSuffix("\\Explorer") && value(s, "Desktop") == "Cosmopolitan" {
            let exe = String(s.dropFirst(pre.count).dropLast("\\Explorer".count))
            adopt(s, "Desktop", "Cosmopolitan", exe)
            if let v = value(pre + exe, "Version") { adopt(pre + exe, "Version", v, exe) }
            if let v = value(pre + exe + "\\Mac Driver", "RetinaMode") { adopt(pre + exe + "\\Mac Driver", "RetinaMode", v, exe) }
        }
        saveLedger(bottle, l)
    }

    // What the launch check wants in the registry for this program ("key|name").
    func wantedRegistry(_ exe: String, _ n: Needs) -> Set<String> {
        let e = "HKCU\\Software\\Wine\\AppDefaults\\" + (exe as NSString).lastPathComponent
        var w: Set<String> = []
        if options(exe)["MOUSE_CAPTURE"] == "1" { w.insert(e + "\\DirectInput|MouseWarpOverride") }
        if n.desktop { w.insert(e + "\\Explorer|Desktop"); w.insert(e + "\\Mac Driver|RetinaMode") }
        if !n.winver.isEmpty { w.insert(e + "|Version") }
        for (dll, _) in n.overrides { w.insert("HKCU\\Software\\Wine\\DllOverrides|" + dll) }
        return w
    }
    // Bottle-wide: adopt pre-ledger values, keep what each known program's launch check wants, remove every other "launch" value
    // (including those of programs no longer in the bottle; launching such a program again writes what it needs).
    func registryWanted(_ bottle: String) -> [String: Set<String>] {   // main actor: needs the program list and launch checks
        Model.adoptLegacyRegistry(bottle)
        let byName = Dictionary(programs.map { (($0 as NSString).lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var m: [String: Set<String>] = [:]
        for exe in Set(Model.ledger(bottle).filter { $0.owner == "launch" }.map { $0.exe.lowercased() }) {
            m[exe] = byName[exe].map { wantedRegistry($0, readiness[$0] ?? launchNeeds($0)) } ?? []
        }
        return m
    }
    nonisolated static func applyRegistrySweep(_ bottle: String, _ wanted: [String: Set<String>]) -> [String] {   // slow Wine calls: off the main actor
        let doomed = ledger(bottle).contains { e in e.owner == "launch" && wanted[e.exe.lowercased()].map { !$0.contains(e.key + "|" + e.name) } == true }
        if doomed { logToFile(snapshot(bottle, "before registry sweep").note) }
        return wanted.sorted { $0.key < $1.key }.flatMap { pruneRegistry(bottle, exe: $0.key, wanted: $0.value) }
    }
    func sweepRegistry(_ bottle: String) -> [String] { Model.applyRegistrySweep(bottle, registryWanted(bottle)) }
}
