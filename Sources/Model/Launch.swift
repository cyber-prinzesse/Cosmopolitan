import SwiftUI

extension Model {
    func extraArgs(_ exe: String) -> [String] {
        guard (exe as NSString).lastPathComponent.lowercased() == "steam.exe" else { return [] }
        // Wine 11 engines draw Steam's window only with its web views on the GPU (GPUAccelWebViewsV3, set in prepare): no GPU-off flags there.
        return engineIsWine11() ? ["-no-cef-sandbox"] : ["-no-cef-sandbox", "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-disable-d3d11"]
    }

    func winPath(_ exe: String) -> String {
        "C:" + exe.components(separatedBy: "/drive_c")[1].replacingOccurrences(of: "/", with: "\\")
    }

    // Dock shortcut: a tiny .app that runs the program in its bottle. Drag it to the Dock.
    // Dock label: macOS names the process after its executable file. A symlink is forgotten (Wine re-execs through the real path) and a
    // bundle path breaks Steam's first window, but a *copy* of the 27 KB loader named after the program, kept in the engine's bin folder so
    // libraries resolve, survives the re-exec — the CrossOver trick. Children inherit it, so Steam's helpers are "Steam" too.
    func loaderNamed(_ exe: String) -> String {
        // Spaces become no-break spaces: the Dock shows them as spaces, but a loader path with an ASCII space breaks programs that start
        // Windows services (GOG Galaxy's client service page-faulted and the client never got its window).
        let ascii = appName(exe).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = ascii.replacingOccurrences(of: " ", with: "\u{00A0}")
        guard name != "wine", !name.isEmpty else { return wineBin }
        let dir = (wineBin as NSString).deletingLastPathComponent, copy = dir + "/" + name, fm = FileManager.default
        if ascii != name { try? fm.removeItem(atPath: dir + "/" + ascii) }   // older copy with real spaces
        let fresh = (try? fm.attributesOfItem(atPath: copy))?[.modificationDate] as? Date ?? .distantPast
        let src = (try? fm.attributesOfItem(atPath: wineBin))?[.modificationDate] as? Date ?? .distantPast
        if fresh < src { try? fm.removeItem(atPath: copy); try? fm.copyItem(atPath: wineBin, toPath: copy) }   // refresh after an engine update
        return fm.fileExists(atPath: copy) ? copy : wineBin
    }
    // The Dock/Launchpad entry of one game (the same launcher the Library keeps for every game, item 37), shown in Finder.
    func makeShortcut(_ exe: String, reveal: Bool = true) {
        let png = icons[exe].flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        log += Model.writeLaunchers(library.filter { $0 != exe }.map { (appName($0), nil) } + [(appName(exe), png)], app: Bundle.main.bundlePath)
        let app = Model.launchersDir + "/\(appName(exe).replacingOccurrences(of: "/", with: "-")).app"
        guard reveal else { return }
        log += "Shortcut: \(app). Drag it to the Dock.\n"
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)])
    }

    // Restricted bottles have no Z:, so an installer outside drive_c (e.g. in Downloads or <bottle>/installers) is staged into C:\installers.
    func stageInstaller(_ path: String, in bottle: String) -> String {
        let c = "\(bottlesDir)/\(bottle)/drive_c", z = "\(bottlesDir)/\(bottle)/dosdevices/z:"
        guard !path.hasPrefix(c + "/"), !FileManager.default.fileExists(atPath: z) else { return path }
        let dir = "\(c)/installers", dst = "\(dir)/\((path as NSString).lastPathComponent)", fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dst)
        if clonefile(path, dst, 0) != 0 { try? fm.copyItem(atPath: path, toPath: dst) }
        return fm.fileExists(atPath: dst) ? dst : path
    }

    // Automatic: no bottle yet -> create one named after the installer, then run it.
    func install(_ url: URL) {
        let path = url.path
        let go: (String) -> Void = { b in
            self.selected = b
            let p = self.stageInstaller(path, in: b)
            let w = p.hasPrefix("\(bottlesDir)/\(b)/drive_c/") ? self.winPath(p) : "Z:" + p.replacingOccurrences(of: "/", with: "\\")
            if p.lowercased().hasSuffix(".msi") { self.wine(b, ["msiexec", "/i", w]) }
            else { let need = self.prepare(p); self.start(need, w, [], exe: p, block: true) }   // installers get the same checks as programs
        }
        if selected.isEmpty {
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
            createBottle(name) { go(name) }
        } else { go(selected) }
    }

    // Launch each program once: skip if its Windows path is already a running process.
    func launch(_ exe: String) {
        // This bottle only (libproc; ps is setuid and can't run sandboxed): the same Windows path in another bottle is another program.
        if !procFind(winPath(exe), under: realPath("\(bottlesDir)/\(selected)")).isEmpty {
            log += "\((exe as NSString).lastPathComponent) is already running.\n"; return
        }
        if let g = epicGames[exe] { log += powerHints(); launchEpic(g.id, exe: exe); return }
        if Store.battlenet.exes.contains(where: { exe.hasSuffix("/" + ($0 as NSString).lastPathComponent) }) { battlenetConfig() }   // keeps the launcher on software rendering
        let (cmd, args) = launchCmd(exe)
        log += powerHints()
        var need = prepare(exe)
        if options(exe)["DRIVERS"] == nil, let d = storeDrivers(exe) { need.drivers = d }   // store clients: DXMT set unless the user chose otherwise
        launchedDrivers[exe] = need.drivers ?? driverList(launchEnvRaw(bottleOf(exe)), bottle: bottleOf(exe))
        for s in Store.allCases where storeExe(s) == exe { need.args += s.args; if s == .epic { finishEpicLauncherUpdate(exe) } }
        // A Steam game inherits Steam's environment, so a driver change OR per-game env from Options… needs Steam restarted with it.
        start(need, cmd, args, exe: exe, restartSteam: steamGames[exe] != nil && (need.drivers != nil || !need.env.isEmpty || need.restartSteam) && steamRunning())
    }

    // Sikarugir's Wine (CrossOver's table in kernelbase.dll) starts …\bin\x64\witcher3.exe, the DirectX 11 build, whenever
    // …\bin\x64_dx12\witcher3.exe is asked for; the game is DirectX 12 only now, so that start fails. bin\x64 → x64_dx12 makes it the same game.
    func linkWitcherRewrite(_ game: String, _ name: String) {
        let d11 = ((game as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/x64", fm = FileManager.default
        guard game.lowercased().hasSuffix("/bin/x64_dx12/witcher3.exe"), (try? fm.attributesOfItem(atPath: d11)) == nil, Model.engineRewritesWitcher else { return }
        snapshot("before linking bin\\x64 to x64_dx12 for \(name)")
        if (try? fm.createSymbolicLink(atPath: d11, withDestinationPath: "x64_dx12")) != nil {
            log += "\(name): this engine starts bin\\x64\\witcher3.exe (the DirectX 11 build) instead of bin\\x64_dx12, which this install doesn't have; bin\\x64 now links to x64_dx12 (delete the link to undo).\n"
        }
    }
    nonisolated static let engineRewritesWitcher: Bool = {
        let k = (wineBin as NSString).deletingLastPathComponent + "/../lib/wine/x86_64-windows/kernelbase.dll"
        return (FileManager.default.contents(atPath: k) ?? Data()).range(of: "\\bin\\x64_dx12\\witcher3.exe".data(using: .utf16LittleEndian)!) != nil
    }()

    // Launch check + the registry it implies (overrides, old-era desktop, Windows version). Returns what start() needs.
    func prepare(_ exe: String) -> Needs {
        var need = launchNeeds(exe)
        need.restartSteam = ensureControllerMode(for: exe)   // DualSense native ⇄ XInput: bus-wide, so Steam must restart when it changes
        log += need.note
        if let red = Model.redGame((exe as NSString).deletingLastPathComponent) { linkWitcherRewrite(red.exe, appName(exe)) }
        // Steam on a Wine 11 engine (measured 24 Oct, tests/oracle/launcher.sh): with its web views off the GPU its window stays black or never
        // appears; this value (before Steam starts), no GPU-off flags and DXMT's cross-process swapchain (LaunchCheck) draw it in 85 s.
        if engineIsWine11(), steamGames[exe] != nil || (exe as NSString).lastPathComponent.lowercased() == "steam.exe",
           Model.regGet(selected, "HKCU\\Software\\Valve\\Steam", "GPUAccelWebViewsV3") != "0x1" {
            Model.regSet(selected, "HKCU\\Software\\Valve\\Steam", "GPUAccelWebViewsV3", "1", type: "REG_DWORD", exe: "steam.exe", owner: "bottle")
        }
        // Community DLL overrides go into the bottle registry (idempotent, same place protonfixes puts them).
        // Every value goes through the registry ledger, so it can be removed again when the setting that wanted it is gone.
        let e = (exe as NSString).lastPathComponent, b = selected
        func reg(_ key: String, _ name: String, _ value: String, owner: String = "launch") { Model.regSet(b, key, name, value, exe: e, owner: owner) }
        // A Windows-version change (set, changed or dropped) gets a snapshot first; the ledger knows the version this program had.
        let oldVer = Model.ledger(b).first { $0.key == "HKCU\\Software\\Wine\\AppDefaults\\\(e)" && $0.name == "Version" }?.value
        if oldVer != (need.winver.isEmpty ? nil : need.winver) { snapshot("before Windows version change: \(e) \(oldVer ?? "default") → \(need.winver.isEmpty ? "default" : need.winver)") }
        if !need.overrides.isEmpty {
            let mark = "\(bottlesDir)/\(selected)/options/.overrides-\((exe as NSString).lastPathComponent)"
            if !FileManager.default.fileExists(atPath: mark) { snapshot("before community DLL overrides for \((exe as NSString).lastPathComponent)"); try? FileManager.default.createDirectory(atPath: (mark as NSString).deletingLastPathComponent, withIntermediateDirectories: true); FileManager.default.createFile(atPath: mark, contents: nil) }
            for (dll, mode) in need.overrides { reg("HKCU\\Software\\Wine\\DllOverrides", dll, mode) }
        }
        // Old program: per-exe virtual desktop + Retina off (AppDefaults keys apply however the exe is started, also via Steam).
        // §9.1 Mouse capture for camera-heavy games: Options MOUSE_CAPTURE=1 → Wine keeps the cursor inside the game window.
        if options(exe)["MOUSE_CAPTURE"] == "1" { reg("HKCU\\Software\\Wine\\AppDefaults\\\(e)\\DirectInput", "MouseWarpOverride", "force") }
        if need.desktop {
            // §7.6 Notch-aware: the virtual desktop never exceeds the area below the notch (safe area), so nothing hides behind it.
            let scr = NSScreen.main, safeW = Int((scr?.frame.width ?? 1280) - (scr?.safeAreaInsets.left ?? 0) - (scr?.safeAreaInsets.right ?? 0)), safeH = Int((scr?.frame.height ?? 960) - (scr?.safeAreaInsets.top ?? 0) - (scr?.safeAreaInsets.bottom ?? 0))
            let want = exeEra(exe).kind == "win16" ? (1024, 768) : (1280, 960)
            let size = "\(min(want.0, safeW))x\(min(want.1, safeH))"
            reg("HKCU\\Software\\Wine\\Explorer\\Desktops", "Cosmopolitan", size, owner: "bottle")
            reg("HKCU\\Software\\Wine\\AppDefaults\\\(e)\\Explorer", "Desktop", "Cosmopolitan")
            reg("HKCU\\Software\\Wine\\AppDefaults\\\(e)\\Mac Driver", "RetinaMode", "n")
        }
        if !need.winver.isEmpty { reg("HKCU\\Software\\Wine\\AppDefaults\\\(e)", "Version", need.winver) }
        let removed = Model.pruneRegistry(b, exe: e, wanted: wantedRegistry(exe, need))   // settings this program no longer needs
        if !removed.isEmpty { log += "Removed registry settings \(e) no longer needs: " + removed.joined(separator: ", ") + "\n" }
        if let t = tuneUnreal(exe) { log += t }
        // Filesystem access: restricted bottles have no Z:. FULL_DISK=1 in cosmopolitan.env restores it (with a warning); removing the line takes it away again.
        let z = "\(bottlesDir)/\(selected)/dosdevices/z:", full = launchEnvRaw()["FULL_DISK"] == "1"
        if full, !FileManager.default.fileExists(atPath: z) { snapshot("before enabling full disk access"); try? FileManager.default.createSymbolicLink(atPath: z, withDestinationPath: "/"); log += "⚠ \(selected): full disk access enabled (FULL_DISK=1) — programs in this bottle can read and write your files.\n" }
        if !full, FileManager.default.fileExists(atPath: z), launchEnvRaw()["FULL_DISK"] == "0" { try? FileManager.default.removeItem(atPath: z); log += "\(selected): full disk access removed.\n" }
        return need
    }

    // Unreal games: once their own settings file exists, turn VSync off (a frame-rate killer under translation) and start the three
    // heaviest scalability groups at Medium if the game hasn't set any. One-shot, marked in the file; the in-game menu stays in charge afterwards.
}
