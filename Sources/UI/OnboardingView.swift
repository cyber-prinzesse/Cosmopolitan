import SwiftUI
import GameController
import UniformTypeIdentifiers

// Item 40: first start, one decision per screen, plain words. Before anything is shown: chip, macOS, memory, free disk, Rosetta, the Game
// Porting Toolkit, installed stores and games; only the screens this Mac needs appear. Every screen after Welcome can be skipped, and
// quitting resumes at the same screen. From the second screen on, the engine downloads in the background with one status line.
struct MacFacts {
    var chip = "", macOS = "", ramGB = 0, freeGB = 0, rosetta = true, controller = false, found: [(store: String, games: Int)] = []
    @MainActor static func check(_ m: Model) -> MacFacts {
        var f = MacFacts()
        f.chip = shell("sysctl -n machdep.cpu.brand_string").trimmingCharacters(in: .whitespacesAndNewlines)
        let v = ProcessInfo.processInfo.operatingSystemVersion; f.macOS = "\(v.majorVersion).\(v.minorVersion)"
        f.ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        f.freeGB = Int(((try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)
        f.rosetta = Model.rosettaInstalled()
        f.controller = !nativeControllers().isEmpty
        for s in Store.allCases {
            let bottles = m.bottles.filter { b in s.exes.contains { FileManager.default.fileExists(atPath: "\(bottlesDir)/\(b)/drive_c/\($0)") } }
            if !bottles.isEmpty { f.found.append((s.rawValue, m.library.filter { p in bottles.contains(m.bottleOf(p)) && !s.exes.contains { p.hasSuffix($0) } }.count)) }
        }
        return f
    }
    // A plain verdict, only when this Mac is limited.
    var limited: String? {
        if ramGB <= 8 { return "Smaller and older games run well; big new games may struggle with \(ramGB) GB of memory." }
        if freeGB < 30 { return "You need about 30 GB free for games. This Mac has \(freeGB) GB free." }
        return nil
    }
}

extension Model {
    // A mounted Game Porting Toolkit disk image: any volume carrying its D3DMetal framework (the test build can name one).
    nonisolated static func mountedGPTK() -> String? {
        if isTestBuild, let t = ProcessInfo.processInfo.environment["COSMO_TEST_GPTK_VOLUME"] { return t }
        return ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { "/Volumes/\($0)" }
            .first { FileManager.default.fileExists(atPath: $0 + "/redist/lib/external/D3DMetal.framework") }
    }
}

struct OnboardingView: View {
    @ObservedObject var m: Model
    @Binding var loginStore: String?
    var finish: () -> Void
    @AppStorage("onboardingStep") var step = 0
    @State var facts = MacFacts()
    @State var rosettaBusy = false
    @State var gptk: String? = nil
    @State var licRead = false
    @State var pressed = false
    @State var started: Date? = nil
    static let titles = ["Welcome", "This Mac", "Rosetta", "Game Porting Toolkit", "Your games", "Controller", "Done"]
    var shown: [Int] { [0] + (facts.limited != nil ? [1] : []) + (facts.rosetta ? [] : [2]) + [3, 4] + (facts.controller ? [5] : []) + [6] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) { ForEach(shown, id: \.self) { i in Capsule().fill(i <= step ? Theme.accent : Color.white.opacity(0.15)).frame(width: 26, height: 5) } }
            Group {
                switch step {
                case 0: welcome
                case 1: thisMac
                case 2: rosetta
                case 3: toolkit
                case 4: games
                case 5: controller
                default: done
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if step > 0 { statusLine }
            HStack {
                if step > 0 && step < 6 { Button("Back") { step = shown.last { $0 < step } ?? 0 } }
                Spacer()
                if step > 0 && step < 6 { Button("Skip") { next() } }
                primary
            }.controlSize(.large).secondaryButton()
        }.padding(32).frame(width: 640, height: 500)
        .interactiveDismissDisabled()
        .onAppear { facts = MacFacts.check(m); gptk = Model.mountedGPTK(); if step > 0 { prepare() } }
        .task { await autoplay() }
    }

    func next() { let from = step; step = shown.first { $0 > step } ?? 6; if isTestBuild { logToFile("onboarding: next \(from) → \(step)\n") }; prepare() }
    // Test build only: walk the real flow by itself, one screen at a time, logging each (COSMO_TEST_ONBOARDING_AUTOPLAY=1); with
    // COSMO_TEST_ONBOARDING_STOP=<screen> it halts there, so a relaunch shows that it resumes. At Done it waits for setup to finish.
    func autoplay() async {
        let env = ProcessInfo.processInfo.environment
        guard isTestBuild, env["COSMO_TEST_ONBOARDING_AUTOPLAY"] == "1" else { return }
        let stop = Int(env["COSMO_TEST_ONBOARDING_STOP"] ?? "") ?? -1
        logToFile("onboarding: \(step == 0 ? "started" : "resumed") at \(Self.titles[step]); screens for this Mac: \(shown.map { Self.titles[$0] }.joined(separator: ", "))\n")
        while step != stop {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if step == 6 {
                while m.setupNeeded && !m.setupStep.hasPrefix("✗") { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                logToFile("onboarding: finished; setup \(m.setupNeeded ? "failed: \(m.setupStep)" : "ready")\n"); startChosenStores(); finish(); return
            }
            if step == 0 { acceptTerms() }
            next(); logToFile("onboarding: at \(Self.titles[step])\n")
        }
    }
    func prepare() {   // the engine downloads in the background from the second screen on; offline it waits for "Try again"
        if m.setupNeeded && !m.setupRunning && m.online { started = Date(); m.runSetup() }
    }

    @ViewBuilder var primary: some View {
        switch step {
        case 0: Button("Get started") { acceptTerms(); next() }.keyboardShortcut(.defaultAction).controlSize(.large).primaryButton()
        case 6: Button("Open my Library") { startChosenStores(); finish() }.keyboardShortcut(.defaultAction).controlSize(.large).primaryButton()
        default: Button("Continue") { next() }.keyboardShortcut(.defaultAction).controlSize(.large).primaryButton()
        }
    }

    @ViewBuilder var statusLine: some View {
        if m.setupNeeded && !m.online && !m.setupRunning {
            HStack { Label("Setup needs the internet once. Connect and press Try again.", systemImage: "wifi.slash").foregroundStyle(.orange); Button("Try again") { prepare() } }
        } else if m.setupRunning {
            HStack { ProgressView(value: m.setupProgress).frame(width: 140); Text("Getting things ready…" + minutesLeft).foregroundStyle(.secondary) }
        } else if m.setupStep.hasPrefix("✗") {
            HStack { Label("Setup didn't finish.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange); Button("Try again") { prepare() } }
        } else if !m.setupNeeded { Label("Everything is ready.", systemImage: "checkmark.circle").foregroundStyle(Theme.accent) }
    }
    var minutesLeft: String {
        guard let s = started, m.setupProgress > 0.05 else { return "" }
        let left = Date().timeIntervalSince(s) / m.setupProgress * (1 - m.setupProgress)
        return left < 60 ? " less than a minute left" : " about \(Int((left / 60).rounded(.up))) minutes left"
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Play your Windows games on this Mac.").font(Cosmo.display(40)).tracking(-0.045 * 40)
            Text("Cosmopolitan sets everything up for each game and keeps it working.").font(Cosmo.body).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) { Text("By continuing you agree to the").font(.caption).foregroundStyle(.secondary); Button("terms of use") { showTerms() }.buttonStyle(.link).foregroundStyle(Theme.accent).font(.caption) }
        }
    }

    var thisMac: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(facts.limited ?? "This Mac plays Windows games well.").font(Cosmo.title)
            Text("\(facts.chip) · \(facts.ramGB) GB memory · macOS \(facts.macOS) · \(facts.freeGB) GB free").foregroundStyle(.secondary)
        }
    }

    var rosetta: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Windows games are made for a different kind of chip. Apple's free Rosetta translates them.").font(Cosmo.title)
            if facts.rosetta { Label("Rosetta is installed.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            else {
                Text("Installing Rosetta means agreeing to Apple's software licence for it.")
                Button("Read Apple's licence") { NSWorkspace.shared.open(URL(string: "https://www.apple.com/legal/sla/")!) }.buttonStyle(.link).foregroundStyle(Theme.accent)
                Button(rosettaBusy ? "Installing Rosetta…" : "Agree and Install") {
                    rosettaBusy = true   // macOS asks for an administrator password; nothing happens before this click
                    Task.detached {
                        _ = shell("osascript -e 'do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges'")
                        await MainActor.run { rosettaBusy = false; facts = MacFacts.check(m) }
                    }
                }.primaryButton().disabled(rosettaBusy || !m.online)
            }
        }
    }

    var toolkit: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Newer games need Apple's free Game Porting Toolkit.").font(Cosmo.title)
            if m.d3dmetalNow != nil, d3dmetalOK {
                Label("Apple's Game Porting Toolkit is ready (version \(m.d3dmetalNow!.pretty)).", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            } else if m.d3dmetalNow != nil, let lic = d3dmetalLicenseFile() {
                Text("Read Apple's licence from your download, then accept it.")
                LicenseView(path: lic).frame(height: 180).border(.secondary.opacity(0.4))
                Toggle("I have read Apple's licence for the Game Porting Toolkit", isOn: $licRead)
                Button("I accept Apple's licence") { m.acceptD3DMetal() }.disabled(!licRead)
            } else if let g = gptk {
                Label("Found it ✓  (\((g as NSString).lastPathComponent))", systemImage: "externaldrive.fill").foregroundStyle(Theme.accent)
                Button("Use it") { m.installD3DMetal(from: g) }.primaryButton()
                Text("Cosmopolitan copies it from your own download; it never downloads it for you.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("1. Open Apple's page.  2. Sign in with your Apple Account and download it.  3. Open the downloaded file.")
                Button("Open Apple's page") { NSWorkspace.shared.open(URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!) }
                Text("Cosmopolitan notices the opened file here. Skip for now: older games work without it, and you can add it later.").font(.caption).foregroundStyle(.secondary)
            }
        }.task { while !Task.isCancelled { gptk = Model.mountedGPTK(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
    }

    @AppStorage("onboardingStores") var chosen = ""   // stores to open or sign in to once the Library opens (a sheet can't open another sheet)
    var games: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where are your games?").font(Cosmo.title)
            ForEach(facts.found, id: \.store) { f in Label("We found \(f.store) with \(f.games) game\(f.games == 1 ? "" : "s"). They're in your Library.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            HStack {
                ForEach(["Steam", "GOG", "Epic Games", "Battle.net"], id: \.self) { s in
                    Toggle(s, isOn: Binding(get: { chosen.split(separator: ",").contains(Substring(s)) }, set: { on in
                        var c = chosen.split(separator: ",").map(String.init).filter { $0 != s }; if on { c.append(s) }; chosen = c.joined(separator: ",") })).toggleStyle(.button)
                }
            }
            Text("You sign in to each store in its own window when your Library opens.").font(.caption).foregroundStyle(.secondary)
            Button("I have an installer file…") {
                let p = NSOpenPanel(); p.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
                if p.runModal() == .OK, let u = p.url { UserDefaults.standard.set(u.path, forKey: "onboardingInstaller") }
            }
        }
    }

    var controller: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Press any button on your controller.").font(Cosmo.title)
            Label(pressed ? "Got it ✓" : nativeControllers().first.map { "\($0) is connected. Waiting for a button…" } ?? "No controller found yet. Turn it on, or pair it in System Settings › Bluetooth.",
                  systemImage: pressed ? "checkmark.circle.fill" : "gamecontroller").foregroundStyle(pressed ? Theme.accent : .primary)
            Button("Test rumble (optional)") { m.testRumble() }
        }.onAppear {
            for c in GCController.controllers() { c.extendedGamepad?.valueChangedHandler = { _, _ in Task { @MainActor in pressed = true } } }
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            if m.setupNeeded {   // never "all set" while setup is still running or didn't finish
                Label("Almost there.", systemImage: "hourglass").font(Cosmo.display(28)).tracking(-0.045 * 28)
                Text("Your Library opens next. Games can start once setup has finished; the line below shows how it's going.").font(Cosmo.body)
            } else {
                Label("You're all set.", systemImage: "checkmark.seal.fill").font(Cosmo.display(28)).tracking(-0.045 * 28).foregroundStyle(Theme.accent)
                Text("Your Library opens next. Add a game with “Add game”; each game says whether it's ready to play.").font(Cosmo.body)
            }
            Spacer()
        }
    }

    func acceptTerms() { FileManager.default.createFile(atPath: support + "/terms-accepted.json", contents: Data("{\"accepted\":\"\(Date())\"}".utf8)) }
    func showTerms() { if let u = Bundle.main.url(forResource: "TERMS", withExtension: "txt") { NSWorkspace.shared.open(u) } }
    func startChosenStores() {   // after onboarding: the stores picked, then a picked installer file
        let picked = chosen.split(separator: ",").map(String.init); chosen = ""
        for s in picked {
            switch s {
            case "Steam": m.addStore(.steam)
            case "Battle.net": m.addStore(.battlenet)
            case "GOG": if m.lgog == nil { m.installLgog() }; loginStore = "gog"
            default: if m.legendary == nil { m.installLegendary() } else { loginStore = "epic" }
            }
        }
        if let f = UserDefaults.standard.string(forKey: "onboardingInstaller") { UserDefaults.standard.removeObject(forKey: "onboardingInstaller"); m.install(URL(fileURLWithPath: f)) }
    }
}
