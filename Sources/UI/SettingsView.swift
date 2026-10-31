import SwiftUI

// Settings window (⌘,). Everything here is stored in UserDefaults and read where it is used:
//  engine          — Wine engine folder under engines/ (default: the tested 10.0_8)
//  autostartSteam  — start Steam with the app when a bottle has it (default on)
//  dailyCleanup    — run Clean up once a day (default on)
//  compatReports   — after a session, offer a prefilled compatibility report for Highball (opt-in, default off; nothing is sent by itself)
//  showAdvanced    — Advanced in the Library, and the Engine and Helper tools sections here (item 39; default off)
struct SettingsView: View {
    @ObservedObject var m = Model.shared
    @AppStorage("showAdvanced") var showAdvanced = false
    @AppStorage("onboardingDone") var onboardingDone = false
    @State var padCheck = ""
    @AppStorage("engine") var engine = defaultEngine
    @AppStorage("autostartSteam") var autostartSteam = true
    @AppStorage("dailyCleanup") var dailyCleanup = true
    @AppStorage("compatReports") var compatReports = false
    @State var tools: [(name: String, path: String?, formula: String, why: String)] = SettingsView.toolStatus()
    @State var installing: String? = nil

    static func toolStatus() -> [(name: String, path: String?, formula: String, why: String)] {
        func find(_ n: String) -> String? { ["/opt/homebrew/bin/\(n)", "/usr/local/bin/\(n)", NSHomeDirectory() + "/.local/bin/\(n)"].first { FileManager.default.fileExists(atPath: $0) } }
        return [("winetricks", find("winetricks"), "winetricks", "fetches runtimes (Visual C++, .NET, fonts) a game is missing"),
                ("DOSBox", find("dosbox"), "dosbox-staging", "runs DOS games"),
                ("Legendary", find("legendary"), "pipx:legendary-gl", "Epic Games library and downloads"),
                ("lgogdownloader", find("lgogdownloader"), "lgogdownloader", "GOG downloads for Windows-only games"),
                // Only with its virus database: clamscan without one finds nothing and fails every scan (freshclam never ran).
                ("ClamAV", find("clamscan").flatMap { p in ["/opt/homebrew/var/lib/clamav", "/usr/local/var/lib/clamav"].contains { d in
                    ["daily.cvd", "daily.cld"].contains { FileManager.default.fileExists(atPath: "\(d)/\($0)") } } ? p : nil },
                 "clamav", "scans downloaded programs for malware (Install also gets its virus database)")]
    }
    var engines: [String] {   // any engine folder with a Wine binary, so a Wine 11 beta added from a folder shows up next to Wine 10
        ((try? FileManager.default.contentsOfDirectory(atPath: support + "/engines")) ?? [])
            .filter { !$0.hasPrefix(".") && FileManager.default.fileExists(atPath: support + "/engines/\($0)/wswine.bundle/bin/wine") }.sorted()
    }

    var body: some View {
        Form {
            Section("Controller") {
                HStack { Button("Check my controller") { let c = nativeControllers(); padCheck = c.isEmpty ? "No controller found. Turn it on, or pair it in System Settings › Bluetooth." : "Connected: " + c.joined(separator: ", ") + ". It should rumble now."; m.testRumble() }
                         Button("Live test…") { m.inputCheck() }.disabled(m.selected.isEmpty) }
                if !padCheck.isEmpty { Text(padCheck).font(.caption) }
            }
            Section("Space") {
                Button("Free up space") { m.runCleanUp() }
                Toggle("Free up space by itself once a day", isOn: $dailyCleanup)
                Text("Removes temporary files, crash dumps, used installers and old download caches. Games and saves are never touched.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Could go (biggest first)") { CleanupList(m: m) }   // item 36: you choose, then confirm
            Section("Setup") {
                Button("Run setup again") { UserDefaults.standard.set(0, forKey: "onboardingStep"); onboardingDone = false }
                Toggle("Start Steam together with Cosmopolitan", isOn: $autostartSteam)
            }
            Section {
                Toggle("Show advanced options", isOn: $showAdvanced)
                Text("Adds Advanced to the Library: graphics components, Apple's toolkit, snapshots, tools and logs.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Compatibility reports") {
                Toggle("Offer a compatibility report after playing a game", isOn: $compatReports)
                Text("Off by default. When on, Cosmopolitan offers a prefilled report for the open Highball database after a session; it is only sent if you submit it yourself on GitHub. Nothing is ever sent automatically.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showAdvanced {
                Section("Engine") {
                    Picker("Wine engine", selection: $engine) {
                        ForEach(Set(engines + [engine, defaultEngine]).sorted(), id: \.self) { e in Text(engineLabel(e)).tag(e) }
                    }
                    .onChange(of: engine) { old, new in if old != new { m.engineSwitched(to: new) } }
                    Text("Wine 10 is the tested engine and stays your safe choice. Wine 11 is a beta: it runs more launchers, but upgrades each bottle the first time it opens, which can't be undone — so a snapshot of every bottle is taken when you switch, and you can roll back from Advanced › Manage bottle › Snapshots.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Add an engine from a folder…") { addEngine() }
                }
                Section("Helper tools (Homebrew)") {
                    ForEach(tools, id: \.name) { t in
                        HStack {
                            Image(systemName: t.path != nil ? "checkmark.circle.fill" : "circle").foregroundStyle(t.path != nil ? Theme.accent : .secondary)
                            VStack(alignment: .leading) { Text(t.name); Text(t.why).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if t.path == nil {
                                Button(installing == t.name ? "Installing…" : "Install") { install(t.name, t.formula) }
                                    .disabled(installing != nil || !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew"))
                            }
                        }
                    }
                    if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
                        Text("Homebrew is not installed (brew.sh); these tools are optional.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).frame(width: 520, height: 600).frost()
    }

    func engineLabel(_ e: String) -> String {
        e + (e == wine10Engine ? "  (Wine 10, tested)" : engineHasDockPatches(e) ? "  (Cosmos, Wine 11, beta)" : engineIsWine11(e) ? "  (Wine 11, beta)" : "")
    }
    // Register an engine the user already has (a folder containing wswine.bundle, e.g. a Highball build) by linking it into the app's
    // engines folder, so it appears in the picker. Nothing is downloaded or copied; the bottle upgrade happens only when it's selected.
    func addEngine() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Add engine"
        p.message = "Choose an engine folder (it contains wswine.bundle)."
        guard p.runModal() == .OK, let u = p.url else { return }
        let src = FileManager.default.fileExists(atPath: u.path + "/wswine.bundle/bin/wine") ? u.path
            : u.lastPathComponent == "wswine.bundle" ? (u.deletingLastPathComponent().path) : ""
        guard !src.isEmpty, FileManager.default.fileExists(atPath: src + "/wswine.bundle/bin/wine") else { m.log += "That folder has no wswine.bundle/bin/wine; not added.\n"; return }
        let name = (src as NSString).lastPathComponent, dst = support + "/engines/\(name)"
        if FileManager.default.fileExists(atPath: dst) { m.log += "An engine named \(name) is already there.\n"; return }
        do { try FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: src); m.log += "Added engine \(name)\(engineIsWine11(name) ? " (Wine 11, beta)" : ""). Choose it above to use it; Wine 10 stays available.\n" }
        catch { m.log += "Could not add the engine: \(error.localizedDescription)\n" }
    }
    func install(_ name: String, _ formula: String) {
        installing = name
        // ClamAV: also its database, with ClamAV's own freshclam (configured from Homebrew's sample, whose "Example" line disables it).
        let clam = "brew install clamav && c=\"$(brew --prefix)/etc/clamav\" && { [ -f \"$c/freshclam.conf\" ] || sed 's/^Example/#Example/' \"$c/freshclam.conf.sample\" > \"$c/freshclam.conf\"; } && freshclam"
        let cmd = formula.hasPrefix("pipx:") ? "command -v pipx >/dev/null || brew install pipx; pipx install \(formula.dropFirst(5))" : formula == "clamav" ? clam : "brew install \(formula)"
        Task.detached {
            _ = shell("export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; \(cmd) >/dev/null 2>&1")
            await MainActor.run { installing = nil; tools = SettingsView.toolStatus() }
        }
    }
}
