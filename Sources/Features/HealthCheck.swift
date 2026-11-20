import Foundation

// Item 35: a health check when the app starts. Rosetta is installed (only onboarding used to check, and an installed Mac can be without
// it: then no game starts); driver folders that came from the pinned template still match it (one you updated through Update… keeps
// <name>.old and is yours, so it isn't flagged); every bottle has Wine Mono; the registry ledger holds no settings of programs that are
// gone; at least 10 GB are free. Problems show in the Library with a Fix button, and "Fix this game" fixes its bottle's first.
extension Model {
    struct HealthProblem: Sendable, Hashable { let kind: String; let target: String; let text: String }   // kind: rosetta, graphics, dotnet, stale, disk
    nonisolated static func rosettaInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") && !(isTestBuild && ProcessInfo.processInfo.environment["COSMO_TEST_NO_ROSETTA"] == "1")
    }
    nonisolated static func freeGB() -> Int {
        if isTestBuild, let t = ProcessInfo.processInfo.environment["COSMO_TEST_FREE_GB"], let n = Int(t) { return n }
        return Int(((try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)
    }
    // programs: each bottle's program file names (lower-case), for the stale-settings check.
    nonisolated static func healthCheck(_ programs: [String: Set<String>]) -> [HealthProblem] {
        var out: [HealthProblem] = [], fm = FileManager.default
        if !rosettaInstalled() { out.append(HealthProblem(kind: "rosetta", target: "", text: "Rosetta is missing: Windows games need Apple's Rosetta to run on this Mac.")) }
        for (part, pin) in Pins.templateTrees where part.hasPrefix("SharedSupport/renderer/") {
            let name = (part as NSString).lastPathComponent, dir = "\(driversDir)/\(name)"
            guard fm.fileExists(atPath: dir), !fm.fileExists(atPath: dir + ".old"), treeHash(dir) != pin else { continue }
            out.append(HealthProblem(kind: "graphics", target: name, text: "A graphics component isn't the version Cosmopolitan installed and tested."))
        }
        for (b, progs) in programs.sorted(by: { $0.key < $1.key }) {
            let pfx = "\(bottlesDir)/\(b)"
            if !fm.fileExists(atPath: pfx + "/drive_c/windows/mono") && !fm.fileExists(atPath: dotnetMarker(pfx)) {
                out.append(HealthProblem(kind: "dotnet", target: b, text: "Support for .NET games is missing in one of your game setups."))
            }
            let stale = ledger(b).filter { $0.owner == "launch" && !progs.contains($0.exe.lowercased()) }
            if !stale.isEmpty { out.append(HealthProblem(kind: "stale", target: b, text: "Settings of \(Set(stale.map(\.exe)).count) removed game\(Set(stale.map(\.exe)).count == 1 ? " are" : "s are") still stored.")) }
        }
        if freeGB() < 10 { out.append(HealthProblem(kind: "disk", target: "", text: "Only \(freeGB()) GB free: games may fail to install or update.")) }
        return out
    }
    func runHealthCheck(then: (@MainActor () -> Void)? = nil) {
        var progs: [String: Set<String>] = [:]
        for b in bottles where FileManager.default.fileExists(atPath: "\(bottlesDir)/\(b)/drive_c") { progs[b] = Set(programsIn(b).map { ($0 as NSString).lastPathComponent.lowercased() }) }
        Task.detached { let r = Model.healthCheck(progs); await MainActor.run { self.healthProblems = r; then?() } }
    }
    // Fixes; only `bottle`'s when given (Fix this game). A graphics component is put back only with a yes (it replaces what is there; the
    // current copy is kept as <name>.old). Low disk space has no automatic fix: Settings › Free up space.
    func fixHealth(bottle: String? = nil) {
        for p in healthProblems where bottle == nil || p.target == bottle || p.kind == "graphics" {
            switch p.kind {
            case "rosetta":   // as onboarding: nothing before the yes; macOS then asks for an administrator password (never in a test build)
                guard ask("Install Rosetta?", "Windows games need Apple's Rosetta. Installing it means agreeing to Apple's software licence (apple.com/legal/sla). macOS asks for an administrator password.", yes: "Agree and Install") else { continue }
                if isTestBuild { log += "Rosetta: test build, installer not started.\n"; continue }
                Task.detached { _ = shell("osascript -e 'do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges'"); await MainActor.run { self.runHealthCheck() } }
            case "graphics":
                guard let app = Pins.verifiedTemplate(), ask("Put back the tested graphics component (\(p.target))?", "It differs from the version Cosmopolitan installed; your current copy is kept as \(p.target).old.", yes: "Put back") else { continue }
                let dst = "\(driversDir)/\(p.target)"
                _ = shell("rm -rf \(shq("\(dst).old")); mv \(shq("\(dst)")) \(shq("\(dst).old")) && cp -cR \(shq("\(app)/Contents/SharedSupport/renderer/\(p.target)")) \(shq("\(dst)"))")
                log += "Graphics component \(p.target) put back to the tested version (the previous copy is \(p.target).old).\n"
            case "dotnet":
                let pfx = "\(bottlesDir)/\(p.target)"
                Task.detached { _ = Model.installWineMono(pfx) { s in Task { @MainActor in self.log += s } } }
            case "stale":
                let removed = sweepRegistry(p.target); log += "Removed \(removed.count) stored setting\(removed.count == 1 ? "" : "s") of removed games.\n"
            default: break
            }
        }
        runHealthCheck()
    }
}
