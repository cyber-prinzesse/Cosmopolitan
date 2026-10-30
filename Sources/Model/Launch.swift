import SwiftUI

extension Model {
    // CEF host: PE imports libcef.dll (delay-load included) and that DLL sits beside the exe. Cached like .gfx- (keyed by size+mtime).
    // steam.exe / steamwebhelper.exe have their own handling and are never treated as generic CEF hosts.
    func cefHost(_ exe: String) -> Bool {
        let base = (exe as NSString).lastPathComponent.lowercased()
        if base == "steam.exe" || base == "steamwebhelper.exe" { return false }
        let fm = FileManager.default, dir = (exe as NSString).deletingLastPathComponent
        let attrs = try? fm.attributesOfItem(atPath: exe)
        let beside = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.lowercased() == "libcef.dll" }
        let key = "\(attrs?[.size] as? Int ?? 0)|\(Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))|\(beside ? 1 : 0)"
        let cache = "\(bottlesDir)/\(bottleOf(exe))/options/.cef-\((exe as NSString).lastPathComponent)"
        if let c = try? String(contentsOfFile: cache, encoding: .utf8), c.hasPrefix(key + "\n") {
            return c.components(separatedBy: "\n").dropFirst().first == "1"
        }
        let yes = beside && exeImports(exe).contains("libcef.dll")
        try? fm.createDirectory(atPath: (cache as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "\(key)\n\(yes ? "1" : "0")\n".write(toFile: cache, atomically: true, encoding: .utf8)
        return yes
    }

    // Steam: its own -cef-* switches. Other CEF hosts (3DMark, EA, Battle.net, …): Chromium's --disable-gpu… or the window stays black under Wine.
    // CEF_GPU=1 or an ARGS that already has --disable-gpu leaves the GPU path alone.
    func extraArgs(_ exe: String) -> [String] {
        let base = (exe as NSString).lastPathComponent.lowercased()
        // Wine 11 engines draw Steam's window only with its web views on the GPU (GPUAccelWebViewsV3, set in prepare): no GPU-off flags there.
        if base == "steam.exe" { return engineIsWine11() ? ["-no-cef-sandbox"] : ["-no-cef-sandbox", "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-disable-d3d11"] }
        if base == "steamwebhelper.exe" { return [] }
        guard cefHost(exe), options(exe)["CEF_GPU"] != "1" else { return [] }
        let user = options(exe)["ARGS"] ?? ""
        return user.contains("--disable-gpu") ? [] : ["--disable-gpu", "--disable-gpu-compositing"]
    }

    func winPath(_ exe: String) -> String {
        "C:" + exe.components(separatedBy: "/drive_c")[1].replacingOccurrences(of: "/", with: "\\")
    }

    // Dock shortcut: a tiny .app that runs the program in its bottle. Drag it to the Dock.
    // Dock label: macOS names the process after its *executable file name* (bin/Steam → "Steam"). LaunchServices display names
    // (cosmo_nodock / CFBundleName) are ignored by the Dock. Cosmo starts Wine through cosmo_wineloader (EngineAddon/), which looks
    // argv[1] up in options/dock-names.txt and execv's a real wine copy named <Name>; WINELOADER stays on the dispatcher so children
    // (games Steam starts, helpers) get their own label too. Fallback host name is still "Steam" for -applaunch, never the game title.
    static let storeLoaderNames = ["Steam", "Battle.net", "Epic Games", "GOG Galaxy", "EA app", "Ubisoft Connect"]
    nonisolated(unsafe) static let wineloaderName = "cosmo_wineloader"
    nonisolated(unsafe) static let wineloaderMarker = "cosmo_dock_loader_v1"
    nonisolated(unsafe) static let wineRealBackup = "wine.cosmo-real"
    // Display → loader file base: ":" / "/" become spaces (not "-"), so "Witcher 3: Wild" stays "Witcher 3 Wild", not "Witcher 3- Wild".
    static func sanitizeLoaderFileName(_ raw: String) -> String {
        var s = raw
        for ch in [":", "/", "\\"] { s = s.replacingOccurrences(of: ch, with: " ") }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "/", with: "-")
        return s.isEmpty ? "wine" : s
    }
    // Which Dock / process name this library exe should use when Cosmopolitan starts Wine for it (fallback when dock-names has no row).
    static func loaderProcessName(for exe: String) -> String {
        let base = (exe as NSString).lastPathComponent.lowercased()
        // Steam games: Cosmo always starts steam.exe -applaunch (SteamLaunch.launchCmd); name after Steam, never the game title.
        if steamGames[exe] != nil || base == "steam.exe" { return "Steam" }
        switch base {
        case "epicgameslauncher.exe": return "Epic Games"
        case "galaxyclient.exe", "galaxyclienthelper.exe": return "GOG Galaxy"
        case "battle.net launcher.exe", "battle.net.exe": return "Battle.net"
        case "eadesktop.exe", "ea desktop.exe", "origin.exe": return "EA app"
        case "ubisoftconnect.exe", "upc.exe": return "Ubisoft Connect"
        default: break
        }
        return sanitizeLoaderFileName(appName(exe))
    }
    nonisolated static func isCosmoWineloader(_ path: String) -> Bool {
        guard let d = FileManager.default.contents(atPath: path), d.count > 32 else { return false }
        return d.range(of: Data(Model.wineloaderMarker.utf8)) != nil
    }
    // Bytes to copy when making a named Dock loader: Wine 11 keeps the real unix loader as wine.cosmo-real.
    nonisolated static func realWineLoader(in dir: String, fallback: String) -> String {
        let backup = dir + "/" + wineRealBackup
        if FileManager.default.fileExists(atPath: backup), !isCosmoWineloader(backup) { return backup }
        if FileManager.default.fileExists(atPath: fallback), !isCosmoWineloader(fallback) { return fallback }
        return fallback
    }
    // Install cosmo_wineloader into bin/ (Wine 10) and, on Wine 11, as lib/wine/x86_64-unix/wine (real → wine.cosmo-real).
    @discardableResult nonisolated static func installWineloaderDispatcher(_ engine: String, tool: String = (Bundle.main.resourcePath ?? "") + "/cosmo_wineloader") -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tool) else { return "" }
        var note = ""
        let bin = engine + "/bin", dest = bin + "/" + wineloaderName
        if !fm.contentsEqual(atPath: tool, andPath: dest) {
            let t = dest + ".new"; try? fm.removeItem(atPath: t)
            guard (try? fm.copyItem(atPath: tool, toPath: t)) != nil else { return "✗ Dock labels: couldn't copy \(wineloaderName) into the engine\n" }
            _ = shell("chmod 755 '\(t)'; codesign --force -s - '\(t)' 2>/dev/null")
            guard rename(t, dest) == 0 else { try? fm.removeItem(atPath: t); return "✗ Dock labels: couldn't install \(wineloaderName)\n" }
            note += "Dock labels: installed \(wineloaderName) into the engine's bin.\n"
        }
        let unix = engine + "/lib/wine/x86_64-unix", unixWine = unix + "/wine"
        if fm.fileExists(atPath: unixWine) || fm.fileExists(atPath: unix) {
            let backup = unix + "/" + wineRealBackup
            if fm.fileExists(atPath: unixWine), !isCosmoWineloader(unixWine) {
                if !fm.fileExists(atPath: backup) {
                    try? fm.copyItem(atPath: unixWine, toPath: backup)
                }
                let t = unixWine + ".cosmo-new"; try? fm.removeItem(atPath: t)
                guard (try? fm.copyItem(atPath: tool, toPath: t)) != nil else { return note + "✗ Dock labels: couldn't stage Wine 11 unix dispatcher\n" }
                _ = shell("chmod 755 '\(t)'; codesign --force -s - '\(t)' 2>/dev/null")
                guard rename(t, unixWine) == 0 else { try? fm.removeItem(atPath: t); return note + "✗ Dock labels: couldn't replace Wine 11 unix wine\n" }
                note += "Dock labels: Wine 11 unix wine is now the dispatcher (real loader: \(wineRealBackup)).\n"
            } else if fm.fileExists(atPath: unixWine), isCosmoWineloader(unixWine), !fm.contentsEqual(atPath: tool, andPath: unixWine) {
                let t = unixWine + ".cosmo-new"; try? fm.removeItem(atPath: t)
                try? fm.copyItem(atPath: tool, toPath: t)
                _ = shell("chmod 755 '\(t)'; codesign --force -s - '\(t)' 2>/dev/null")
                _ = rename(t, unixWine)
            }
        }
        return note
    }
    // Remove leftover loader copies that are byte-identical to the real wine loader (never other files). Keeps store host names + the
    // one in use, and every copy a running process was started from: Wine starts a program's child processes (REDprelauncher →
    // witcher3.exe, crash handlers, launcher hand-offs) through the same file, so deleting it under a running game breaks its next child.
    static func pruneWineLoaderCopies(binDir: String, winePath: String, keeping: Set<String>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: binDir) else { return }
        let running = runningExecutables()
        let protected: Set<String> = [wineloaderName, wineRealBackup, "wine", "wineserver"]
        for f in items where !protected.contains(f) {
            let path = binDir + "/" + f
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if keeping.contains(f) || running.contains(path) || running.contains(realPath(path)) { continue }
            if isCosmoWineloader(path) { continue }
            guard fm.contentsEqual(atPath: path, andPath: winePath) else { continue }   // only exact wine copies
            try? fm.removeItem(atPath: path)
        }
    }
    // Executable paths of every process (libproc: `ps` is setuid and can't run sandboxed).
    static func runningExecutables() -> Set<String> {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var out = Set<String>(), buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        for p in pids.prefix(max(got, 0)) where p > 0 && proc_pidpath(p, &buf, UInt32(buf.count)) > 0 { out.insert(String(cString: buf)) }
        return out
    }
    // Path Cosmo exec's: the dispatcher. Also ensures a wine copy for the host fallback name exists (children / no dock-names row).
    func loaderNamed(_ exe: String) -> String {
        _ = Model.installWineloaderDispatcher(engineDir)
        let ascii = Model.loaderProcessName(for: exe)
        let name = ascii.replacingOccurrences(of: " ", with: "\u{00A0}")
        let bin = (wineBin as NSString).deletingLastPathComponent, fm = FileManager.default
        let dispatch = bin + "/" + Model.wineloaderName
        let real = Model.realWineLoader(in: bin, fallback: wineBin)
        var keep = Set(Model.storeLoaderNames.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") })
        keep.formUnion(Model.storeLoaderNames)
        keep.insert(name); keep.insert(ascii); keep.insert(Model.wineloaderName)
        if name != "wine", !name.isEmpty {
            if ascii != name { try? fm.removeItem(atPath: bin + "/" + ascii) }
            let copy = bin + "/" + name
            let fresh = (try? fm.attributesOfItem(atPath: copy))?[.modificationDate] as? Date ?? .distantPast
            let src = (try? fm.attributesOfItem(atPath: real))?[.modificationDate] as? Date ?? .distantPast
            if !fm.fileExists(atPath: copy) || Model.isCosmoWineloader(copy) || fresh < src {
                try? fm.removeItem(atPath: copy); try? fm.copyItem(atPath: real, toPath: copy)
            }
        }
        Model.pruneWineLoaderCopies(binDir: bin, winePath: real, keeping: keep)
        // Wine 11: named copies + prune beside ntdll (unix wine is the dispatcher).
        if engineIsWine11() {
            let unix = engineDir + "/lib/wine/x86_64-unix"
            let ureal = Model.realWineLoader(in: unix, fallback: unix + "/" + Model.wineRealBackup)
            if name != "wine", !name.isEmpty, fm.fileExists(atPath: ureal) {
                let copy = unix + "/" + name
                let fresh = (try? fm.attributesOfItem(atPath: copy))?[.modificationDate] as? Date ?? .distantPast
                let src = (try? fm.attributesOfItem(atPath: ureal))?[.modificationDate] as? Date ?? .distantPast
                if !fm.fileExists(atPath: copy) || Model.isCosmoWineloader(copy) || fresh < src {
                    try? fm.removeItem(atPath: copy); try? fm.copyItem(atPath: ureal, toPath: copy)
                }
            }
            Model.pruneWineLoaderCopies(binDir: unix, winePath: ureal, keeping: keep)
        }
        return fm.fileExists(atPath: dispatch) ? dispatch : wineBin
    }
    // The Dock/Launchpad entry of one game (the same launcher the Library keeps for every game, item 37), shown in Finder.
    func makeShortcut(_ exe: String, reveal: Bool = true) {
        let png = icons[exe].flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        log += Model.writeLaunchers(library.filter { $0 != exe }.map { (appName($0), nil) } + [(appName(exe), png)], app: Bundle.main.bundlePath)
        let app = Model.launchersDir + "/\(Model.launcherFileName(appName(exe))).app"
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
        // Drop a leftover driver-fallback pin on steam.exe before prepare reads Options: games inherit Steam's env, so DXVK there breaks DX12.
        // Wine's tray hidden (templates set it): Steam's window close has nowhere to minimize to, so the window keeps coming back.
        if exe.lowercased().hasSuffix("/steam/steam.exe") { clearSteamHostDriverFallback(exe); Model.healSteamSystray(bottleOf(exe)); Model.healSteamDockIcon(bottleOf(exe)) }
        log += Model.installNoDockAddon(engineDir)   // engine add-on current before any program starts (Dock icon)
        log += Model.installWineloaderDispatcher(engineDir)   // Dock label = loader file name (cosmo_wineloader)
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
