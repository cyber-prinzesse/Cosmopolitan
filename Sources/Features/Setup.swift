import SwiftUI

// First-run setup: everything a fresh Mac needs, downloaded and prepared with progress.
//  1. Sikarugir template (the engine's dylibs, MoltenVK, GStreamer, and the driver builds DXMT/DXVK/D9VK/cnc-ddraw);
//  2. the Wine engine chosen in Settings (default: the tested 10.0_8);
//  3. engine fix-ups (prepareEngine), drivers and GStreamer copied into Cosmopolitan's own folders.
// D3DMetal is never copied (Apple's license: the user installs it from Apple's download via Drivers › D3DMetal…).
// Homebrew helpers (winetricks, DOSBox) are offered, not forced; they need Homebrew, which Cosmopolitan does not install.
extension Model {
    var setupNeeded: Bool { !engineOK || !FileManager.default.fileExists(atPath: driversDir + "/dxmt/wine") }

    func runSetup() {
        guard !setupRunning else { return }
        setupRunning = true; setupProgress = 0; setupStep = "Starting…"
        let engine = engineName
        Task.detached {
            let step: @Sendable (String, Double) -> Void = { s, p in Task { @MainActor in self.setupStep = s; self.setupProgress = p; self.log += s + "\n" } }
            let ok = Model.performSetup(engine: engine, step: step)
            await MainActor.run {
                self.setupRunning = false
                if ok { self.showSetup = false; self.log += "Setup finished. Create a bottle or drop a Windows installer into the window.\n"; self.refresh() }
            }
        }
    }

    nonisolated static func performSetup(engine: String, step: @escaping (String, Double) -> Void) -> Bool {
        let fm = FileManager.default
        let tplDir = NSHomeDirectory() + "/Library/Application Support/Sikarugir/Template"
        // 1. The pinned Sikarugir template. Its d3dmetal and apple_gptk folders (Apple's D3DMetal) are never extracted; the parts used are
        //    checked against their pinned tree hashes before anything is copied.
        step("Checking the Sikarugir template \(Pins.sikarugirTemplate)…", 0.02)
        let app = "\(tplDir)/\(Pins.sikarugirTemplate).app"
        if !fm.fileExists(atPath: app) {
            step("Downloading \(Pins.sikarugirTemplate) (about 150 MB)…", 0.05)
            _ = shell("mkdir -p '\(tplDir)' && cd '\(tplDir)' && curl -sfL -m 1200 -o t.tar.xz '\(Pins.sikarugirTemplateURL)' && tar xf t.tar.xz --exclude '*/renderer/d3dmetal*' --exclude '*/renderer/apple_gptk*'; rm -f t.tar.xz")
            guard fm.fileExists(atPath: app) else { step("✗ Template download failed. Try again.", 0); return false }
        }
        if let bad = Pins.templateTrees.keys.sorted().first(where: { Pins.templateTree(app, $0) != Pins.templateTrees[$0] }) {
            step("✗ The Sikarugir template doesn't match the pinned \(Pins.sikarugirTemplate) (\(bad)); nothing installed.", 0); return false
        }
        // 2. Engine
        let engRoot = "\(support)/engines/\(engine)"
        if !fm.fileExists(atPath: engRoot + "/wswine.bundle/bin/wine") {
            step("Downloading the Wine engine \(engine) (about 160 MB)…", 0.35)
            let local = NSHomeDirectory() + "/Library/Application Support/Sikarugir/Engines/\(engine).tar.xz"
            guard engine == Pins.sikarugirEngine.version else { step("✗ Only the pinned engine \(Pins.sikarugirEngine.version) can be installed; choose it in Settings.", 0); return false }
            // The local copy only if it has the pinned SHA-256; otherwise the pinned download (checked, cached).
            guard let tarball = sha256File(local) == Pins.sikarugirEngine.sha256 ? local : fetchPinned(Pins.sikarugirEngine, log: { step($0.trimmingCharacters(in: .whitespacesAndNewlines), 0.45) }) else {
                step("✗ The engine download failed or didn't match its pinned SHA-256; nothing installed.", 0); return false
            }
            step("Unpacking the engine…", 0.6)
            _ = shell("mkdir -p '\(engRoot)' && cd '\(engRoot)' && tar xf '\(tarball)'")
            guard fm.fileExists(atPath: engRoot + "/wswine.bundle/bin/wine") else { _ = shell("rm -rf '\(engRoot)'"); step("✗ Engine download failed. Try again.", 0); return false }
        }
        step("Preparing the engine (libraries, MoltenVK, GStreamer)…", 0.7)
        let prep = prepareEngine(engRoot + "/wswine.bundle")
        step(prep.trimmingCharacters(in: .whitespacesAndNewlines), 0.8)
        // 3. Drivers from the template (never D3DMetal)
        step("Installing graphics drivers (DXMT, DXVK, D9VK, cnc-ddraw)…", 0.85)
        _ = shell("mkdir -p '\(driversDir)'")
        for d in ["dxmt", "dxvk", "dxvk3", "d9vk", "cnc_ddraw"] where !fm.fileExists(atPath: "\(driversDir)/\(d)/wine") {
            _ = shell("cp -cR '\(app)/Contents/SharedSupport/renderer/\(d)' '\(driversDir)/\(d)' 2>/dev/null")
        }
        guard fm.fileExists(atPath: driversDir + "/dxmt/wine") else { step("✗ Drivers missing from the template. Try again.", 0); return false }
        let wine = "\(engRoot)/wswine.bundle/bin/wine"
        let v = shell("'\(wine)' --version 2>&1 | head -1")
        guard v.hasPrefix("wine-") else { step("✗ The engine does not start: \(v.prefix(80))", 0); return false }
        // 4. A first bottle, so a fresh Mac can install something right away (same steps as Create: wineboot, SDL pads, Windows 10, no Z:).
        let bottles = ((try? fm.contentsOfDirectory(atPath: bottlesDir)) ?? []).filter { !$0.hasPrefix(".") }
        if bottles.isEmpty {
            step("Creating the first bottle \"Games\"…", 0.92)
            let pfx = "\(bottlesDir)/Games"
            let env = "WINEPREFIX='\(pfx)' WINEDEBUG=-all WINEMSYNC=1 WINEDLLOVERRIDES='mscoree,mshtml='"
            PreparingWindow.begin(bottle: "Games")
            _ = shell("mkdir -p '\(pfx)'; \(env) '\(wine)' wineboot -u >/dev/null 2>&1; \(env) '\(wine)' reg add 'HKLM\\System\\CurrentControlSet\\Services\\winebus' /v DisableHidraw /t REG_DWORD /d 1 /f >/dev/null 2>&1; \(env) '\(wine)' winecfg -v win10 >/dev/null 2>&1; '\(engRoot)/wswine.bundle/bin/wineserver' -w; rm -f '\(pfx)/dosdevices/z:'")
            PreparingWindow.end()
            guard fm.fileExists(atPath: "\(pfx)/drive_c/windows/system32/kernel32.dll") else { step("✗ The first bottle could not be created.", 0); return false }
            step("Installing .NET support (Wine Mono from WineHQ)…", 0.95)
            if !installWineMono(pfx, log: { step($0.trimmingCharacters(in: .whitespacesAndNewlines), 0.97) }) { step("⚠ .NET support could not be installed now; it is retried before the first .NET program starts.", 0.97) }
        }
        // Microsoft runtimes, pinned: downloaded and checked now, installed into a bottle when a program needs them.
        step("Downloading Microsoft runtimes (Visual C++ v14 x86/x64, DirectX June 2010)…", 0.98)
        for r in Runtime.allCases where fetchPinned(r.pin, log: { step($0.trimmingCharacters(in: .whitespacesAndNewlines), 0.98) }) == nil {
            step("⚠ \(r.pin.name) could not be downloaded now; it is fetched again when a program needs it.", 0.98)
        }
        step("✓ Ready: \(v), drivers installed, bottle ready.", 1)
        return true
    }
}

extension ContentView {
    @ViewBuilder var setupSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Cosmopolitan").font(.title2.bold())
            Text("Cosmopolitan needs a Wine engine and graphics drivers before it can run Windows programs. This downloads about 300 MB from the open-source Sikarugir project and prepares everything. It takes a few minutes.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Engine: \(engineName)").font(.caption).foregroundStyle(.secondary)
            if m.setupRunning || m.setupProgress > 0 {
                ProgressView(value: m.setupProgress)
                Text(m.setupStep).font(.caption).lineLimit(2)
            }
            HStack {
                if !m.setupRunning && m.engineReady { Button("Close") { m.showSetup = false } }
                Spacer()
                Button(m.setupStep.hasPrefix("✗") ? "Try again" : "Set up") { m.runSetup() }
                    .keyboardShortcut(.defaultAction).disabled(m.setupRunning)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(m.setupRunning)
    }
}
