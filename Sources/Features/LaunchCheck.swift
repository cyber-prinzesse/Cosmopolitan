import SwiftUI

extension Model {
    struct Needs { var drivers: [String]?; var verbs: [String]; var note: String; var overrides: [(String, String)] = []; var env: [String: String] = [:]; var args: [String] = []; var desktop = false; var winver = ""; var status: Color = .green; var dx12 = false; var anticheat: (Color, String)? = nil; var restartSteam = false; var needsDotNet = false; var runtimes: [Runtime] = [] }
    func launchNeeds(_ exe: String) -> Needs {
        let bottle = bottleOf(exe)   // the program's own bottle, whichever is selected (the Library shows every bottle's games)
        let name = (exe as NSString).lastPathComponent, dir = (exe as NSString).deletingLastPathComponent, fm = FileManager.default
        if peRead(exe).info.error != 0 {   // truncated or malformed header: a clear answer instead of a guess
            var n = Needs(drivers: nil, verbs: [], note: "Launch check \(name): unreadable executable (damaged or truncated file)\n"); n.status = .red; return n
        }
        var imps = exeImports(exe), impSrc = exe   // the exe imps came from (switches to the real game below)
        // CD Projekt's REDprelauncher (The Witcher 3, Cyberpunk 2077): launcher-configuration.json names the real game. Inspect that one, with
        // its own folder's DLLs (they show Direct3D 12), and start it with --launcher-skip: REDlauncher's Qt window can't get an OpenGL
        // context here, and the prelauncher clears Qt's environment variables, so the launcher can't be helped from outside.
        let cdpr = Model.redGame(dir), adir = cdpr.map { ($0.exe as NSString).deletingLastPathComponent } ?? dir
        if let cdpr { imps = exeImports(cdpr.exe); impSrc = cdpr.exe }
        // Unreal games ship a tiny bootstrap exe; the real one is <Game>/Binaries/Win64/<Game>-Win64-Shipping.exe. Inspect that instead.
        if !imps.contains(where: { $0.hasPrefix("d3d") || $0 == "vulkan-1.dll" || $0 == "opengl32.dll" }), fm.fileExists(atPath: dir + "/Engine"),   // Unreal install root only
           let en = fm.enumerator(atPath: dir), let real = en.compactMap({ $0 as? String }).first(where: { $0.lowercased().hasSuffix("-shipping.exe") || ($0.contains("/Binaries/Win64/") && $0.lowercased().hasSuffix(".exe") && !$0.hasPrefix("Engine/")) }) {
            imps = exeImports("\(dir)/\(real)"); impSrc = "\(dir)/\(real)"
        }
        // Agility SDK / DXIL beside the exe: hard evidence of Direct3D 12 — add d3d12.dll so the DX11-default string guard does not drop it.
        // D3D12CreateDevice alone stays a graphicsAPIs string cue (Witcher 3's DX11 build has it and must keep DXMT).
        if !imps.contains("d3d12.dll"), runtimeShipsD3D12Files(impSrc) { imps.append("d3d12.dll") }
        let beside = Model.besideImports(adir).subtracting(imps)   // item 28: what the DLLs next to it import
        let local = Set(((try? fm.contentsOfDirectory(atPath: adir)) ?? []).map { $0.lowercased() })
        let sys = Set(((try? fm.contentsOfDirectory(atPath: "\(bottlesDir)/\(bottle)/drive_c/windows/system32")) ?? []).map { $0.lowercased() })
        let missing = imps.filter { !$0.hasPrefix("api-ms-") && !$0.hasPrefix("ext-ms-") && !builtinDLLs.contains($0) && !local.contains($0) && !sys.contains($0) }
        // A builtin Wine DLL only loads if its stub file exists in system32 (64-bit) / syswow64 (32-bit). If something deleted the stub
        // (an uninstaller, a DirectX redist cleanup), the game dies at start with "Library X not found"; put the engine's copy back.
        let win = "\(bottlesDir)/\(bottle)/drive_c/windows", lib = (wineBin as NSString).deletingLastPathComponent + "/../lib/wine"
        let is32 = peRead(exe).info.machine == 0x14c
        for d in imps where builtinDLLs.contains(d) && !local.contains(d) {
            let dst = "\(win)/\(is32 ? "syswow64" : "system32")/\(d)", src = "\(lib)/\(is32 ? "i386" : "x86_64")-windows/\(d)"
            if !fm.fileExists(atPath: dst), fm.fileExists(atPath: src), (try? fm.copyItem(atPath: src, toPath: dst)) != nil { log += "Restored missing Wine library \(d) for \(name).\n" }
        }
        var parts: [String] = [], drivers: [String]? = nil
        // Era: 9x-era PE (subsystem 4), Win16 and DirectDraw titles get a per-program virtual desktop with Retina off; DOS goes to DOSBox.
        let era = exeEra(exe)
        var desktop = false
        var winver = ""   // Windows version reported to this exe when the picker is on "auto"
        switch era.kind {
        case "dos": parts.append(FileManager.default.fileExists(atPath: "/opt/homebrew/bin/dosbox") ? "DOS program — runs in DOSBox" : "DOS program — brew install dosbox-staging first")
        case "win16": desktop = true; winver = "win98"; parts.append("16-bit Windows program — 1024x768 virtual desktop, Retina off")
        default:
            let msvc = era.linker != 2   // GNU ld stamps subsystem 4/5 on new programs; only trust the number from Microsoft/Borland linkers
            // Installer stubs (NSIS/Inno: SteamSetup.exe, …) carry old-looking headers but install modern software that refuses Windows 98.
            let installer = exe.contains("/installers/") || ["setup", "install"].contains(where: { name.lowercased().contains($0) })
            // .NET programs: csc and mcs stamp subsystem 4.0 on every build, so the header says nothing about age (.NET 4 doesn't run on 9x at all).
            if installer || imps.contains("mscoree.dll") { break }
            // 64-bit builds postdate Windows 9x, so only 32-bit programs can be 9x-era.
            if is32, (era.subsystem > 0 && era.subsystem <= 4 && msvc) || imps.contains("ddraw.dll") { desktop = true; winver = "win98"; parts.append("Windows 9x-era program — 1280x960 virtual desktop, Retina off") }
            else if era.subsystem == 5 && (6...9).contains(era.linker) { winver = "winxp"; parts.append("XP-era program") }   // VC6–VC2008 builds
        }
        if template == "auto", !winver.isEmpty { parts.append("reports Windows as \(winver)") }
        // Driver plan from facts: APIs the game uses (imports + runtime loads), its 32/64-bit build, and what each installed driver ships.
        let highball = steamGames[exe].map { communityFixes($0.id).renderer }.flatMap { ["d3dmetal": "d3dmetal", "dxmt": "dxmt", "dxvk": "dxvk", "dxvk-moltenvk": "dxvk"][$0] }
        let besideGfx = beside.filter { $0.hasPrefix("d3d1") || $0 == "d3d9.dll" || $0 == "d3d8.dll" || $0 == "ddraw.dll" }
        let plan = driverPlan(exe, imports: imps + besideGfx.sorted(), prefer: highball)
        if !besideGfx.isEmpty { parts.append("the DLLs beside it use " + besideGfx.sorted().joined(separator: ", ")) }
        if !plan.apis.isEmpty { parts.append((plan.is32 ? "32-bit " : "64-bit ") + plan.why.joined(separator: ", ")) }
        else if let gfx = [("vulkan-1.dll", "Vulkan"), ("opengl32.dll", "OpenGL")].first(where: { imps.contains($0.0) }) { parts.append(gfx.1) }
        for api in plan.missing { parts.append("\(api) driver not installed for this build") }   // red light: it will not render
        if batteryCapWanted(), options(exe)["FULL_SPEED"] != "1", plan.drivers.contains("d3dmetal") || (drivers == nil && plan.apis.contains("Direct3D 12")) {   // honest battery cap
            parts.append(d3dmetalFrameCap() ? "battery: D3DMetal caps this game at 60 fps"
                         : "battery 60 fps cap: not available for this game (D3DMetal \(Model.d3dmetalInfo(driversDir + "/d3dmetal")?.pretty ?? "") has no frame limiter); use the game's own frame limit or vsync")
        }
        if let fixed = storeDrivers(exe) { drivers = fixed; parts.append("store client: \(fixed.joined(separator: "+"))") }   // its UI is tested on these
        else if !plan.drivers.isEmpty, !serves(driverList(launchEnvRaw(bottle), bottle: bottle), plan) {
            drivers = plan.drivers; parts.append("using \(plan.drivers.joined(separator: "+")) for this launch")
        }
        // Missing DLLs that a pinned Microsoft runtime provides are installed from Microsoft's own installer before the launch.
        var runtimes = Set(missing.compactMap { Model.runtimeFor(dll: $0, is32: is32) })
        for d in beside where !local.contains(d) && !sys.contains(d) { if let r = Model.runtimeFor(dll: d, is32: is32) { runtimes.insert(r) } }
        // Visual C++ 2015–2022 (item 28): an import of the program or of the DLLs beside it needs Microsoft's runtime in the program's bitness
        // unless the game ships the DLL or the bottle's copy is already Microsoft's; Wine's own stand-in is in every bottle, so present isn't enough.
        for d in Set(imps).union(beside) where !local.contains(d) {
            if let r = Model.runtimeFor(dll: d, is32: is32), r != .directx, !Model.isMicrosoftDLL("\(win)/\(is32 ? "syswow64" : "system32")/\(d)") { runtimes.insert(r) }
        }
        var verbs = Array(Set(missing.compactMap { depVerbs[$0] })).sorted()
        // .NET: ready only once the probe program has actually run in this bottle (Wine Mono from WineHQ, installed with the bottle).
        var dotnet = ""   // "", "pending" (not checked yet), "bad" (probe failed)
        if imps.contains("mscoree.dll") || peRead(exe).info.clr != 0 {   // the .NET header counts too (item 28)
            let pfx = "\(bottlesDir)/\(bottle)"
            if fm.fileExists(atPath: Model.dotnetMarker(pfx)) { parts.append(".NET app (.NET verified in this bottle)") }
            else if fm.fileExists(atPath: Model.dotnetFailMarker(pfx)) { dotnet = "bad"; parts.append(".NET doesn't run in this bottle yet — launching it or Repair installs Wine Mono from WineHQ") }
            else { dotnet = "pending"; parts.append(".NET app (.NET not checked in this bottle yet; checked before the first launch)") }
        }
        // Steam game: what Linux players needed (umu-protonfixes) is what we need too, minus Proton-only knobs.
        var n = Needs(drivers: drivers, verbs: [], note: "", desktop: desktop, winver: template == "auto" ? winver : "", dx12: plan.apis.contains("Direct3D 12") && !plan.is32)
        // Anti-cheat: local signatures first (works for any program), then the community map for Steam games. Never bypassed — only reported honestly.
        // Scan the game's own root: for a Steam game that is steamapps/common/<Game> (never the whole library), otherwise the exe's folder.
        let gameRoot: String = { if let r = exe.range(of: "/steamapps/common/") { let rest = exe[r.upperBound...]; if let s = rest.firstIndex(of: "/") { return String(exe[..<s]) } }; return dir }()
        var acNames = antiCheatSignatures(in: gameRoot)
        if let g = steamGames[exe] {
            let c = communityFixes(g.id)
            if !c.tier.isEmpty { parts.append("ProtonDB \(c.tier)") }
            acNames += c.anticheat.filter { !acNames.contains($0) }
            // Highball's curated backend only orders the choice inside the driver plan above (it cannot pick a driver lacking the game's DLLs).
            if !c.renderer.isEmpty { parts.append("Highball \(c.hbStatus): \(c.renderer)") }
            let applied = Model.winetricksApplied("\(bottlesDir)/\(bottle)")
            for v in c.verbs {
                // The Witcher 3 5.0 turns on Streamline, ray tracing and frame generation when it can't see Wine, which Proton's fix hides:
                // right with an NVIDIA card on Linux, a crash at start under D3DMetal. So not on D3DMetal, and undone once if it was applied.
                if v == "hidewineexports=enable", plan.drivers.contains("d3dmetal") { if applied["hidewineexports"] == "enable" { verbs.append("hidewineexports=disable") }; continue }
                let kv = v.split(separator: "=", maxSplits: 1).map(String.init)
                if applied[kv[0]] == (kv.count == 2 ? kv[1] : "") { continue }   // winetricks.log says it's in: no second run (it stops Steam)
                let r = Model.runtimesFor(verb: v); if r.isEmpty { if !verbs.contains(v) { verbs.append(v) } } else { runtimes.formUnion(r) }   // pinned Microsoft runtimes instead of winetricks
            }
            n.overrides = c.overrides; n.env = c.env; n.args = c.args
            if !(c.verbs.isEmpty && c.overrides.isEmpty && c.env.isEmpty && c.args.isEmpty) { 
                let ov: String = c.overrides.isEmpty ? "" : " (overrides: \(c.overrides.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")))"
                let ar: String = c.args.isEmpty ? "" : " args \(c.args.joined(separator: " "))"
                parts.append("applying community fixes\(ov)\(ar)")
            }
            if !c.launchArgs.isEmpty { n.args += c.launchArgs.split(separator: " ").map(String.init) }
        }
        if let v = antiCheatVerdict(acNames, appid: steamGames[exe]?.id, name: steamGames[exe]?.name ?? appName(exe)) { n.anticheat = v; parts.append(v.1) }
        // §8.2 Untrusted executable: not installed by a store client. Warn, never block.
        if steamGames[exe] == nil, !exe.lowercased().hasSuffix("/steam/steam.exe"), !exe.contains("/drive_c/windows/"), !exe.contains("/Program Files/Windows NT/") {
            parts.append("not installed through a store — run only if you trust where it came from")
        }
        // AVX (§7.2/§4.3): known from the cached disassembly count; Rosetta advertises AVX only to programs that have AVX code.
        if let c = avxCount(exe), c > 500 { n.env["ROSETTA_ADVERTISE_AVX"] = "1"; parts.append("uses AVX (Rosetta AVX on)" + (avx512Count(exe) > 1000 ? "; also has AVX-512 paths, which Rosetta never offers — the game falls back by itself" : "")) }
        else if avxCount(exe) == nil, era.kind == "pe" { parts.append("AVX scan pending") }
        // CEF host: Chromium's window stays black under Wine unless the GPU path is off (3DMark Demo 2026-10-29; Steam already has its own -cef-*).
        if cefHost(exe), options(exe)["CEF_GPU"] != "1", !(options(exe)["ARGS"]?.contains("--disable-gpu") ?? false) {
            parts.append("embedded browser window: drawn without the GPU")
        }
        // Per-program options (right-click → Options…): ARGS, DRIVERS, any other KEY=VALUE becomes environment. They win over detection.
        let o = options(exe)
        if let cdpr { n.args += ["--launcher-skip"] + (cdpr.flag.isEmpty ? [] : [cdpr.flag]); parts.append("starts \((cdpr.exe as NSString).lastPathComponent) without REDlauncher") }
        // Steam on a Wine 11 engine: its web helper's GPU process draws into steam.exe's window, which DXMT allows only when asked (with
        // GPU web views on and no GPU-off flags: Steam's sign-in window after 85 s; without it none in 600 s). Steam games inherit it.
        // SteamSetup.exe too: its "Run Steam" starts steam.exe itself, which then inherits this; without it the sign-in window can't
        // get a swap chain (SwapChain11::reset 0x80004005, eglCreateWindowSurface EGL_BAD_ALLOC) and Steam runs with no window.
        if engineIsWine11(), ["steam.exe", "steamsetup.exe"].contains(name.lowercased()) { n.env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] = "1" }
        if let a = o["ARGS"], !a.isEmpty { n.args += a.split(separator: " ").map(String.init) }
        if let d = o["DRIVERS"], !d.isEmpty { drivers = d.split(separator: ",").map(String.init); n.drivers = drivers }
        for (k, v) in o where !["ARGS", "DRIVERS", "FOCUS_SHORTCUT", "PAUSE_IN_BACKGROUND", "MOUSE_CAPTURE", "CEF_GPU", "STEAM_IDLE_DIET"].contains(k) { n.env[k] = v }
        // §7.10 Locale: LANG=ja_JP.UTF-8 (etc.) reaches Wine as-is; CJK locales also get the matching fonts so old games don't show boxes.
        if let l = o["LANG"], ["ja", "zh", "ko"].contains(where: { l.hasPrefix($0) }), !verbs.contains("cjkfonts") { verbs.append("cjkfonts"); parts.append("locale \(l) + CJK fonts") }
        if !o.isEmpty { parts.append("custom options: " + o.keys.sorted().joined(separator: " ")) }
        // Delay-load-only imports (e.g. Epic's libcef.dll, loaded at runtime from the launcher's own folders) don't block startup, so a
        // missing one is not a "Won't run" DLL. They still count for the proactive runtime/verb installs above when they map to one.
        let optional = Set(exeDelayImports(impSrc))
        let unknown = missing.filter { !optional.contains($0) && depVerbs[$0] == nil && Model.runtimeFor(dll: $0, is32: is32) == nil }
        let pfxR = "\(bottlesDir)/\(bottle)"
        n.runtimes = runtimes.filter { !fm.fileExists(atPath: Model.runtimeMarker(pfxR, $0)) }.sorted { $0.rawValue < $1.rawValue }
        if !n.runtimes.isEmpty { parts.append("installs " + n.runtimes.map { $0.pin.name }.joined(separator: ", ") + " from Microsoft first") }
        if !verbs.isEmpty { parts.append(winetricks == nil ? "needs \(verbs.joined(separator: " ")) — brew install winetricks to fetch automatically" : "fetching \(verbs.joined(separator: " ")) via winetricks") }
        if !unknown.isEmpty { parts.append("missing DLLs: " + unknown.joined(separator: ", ")) }
        // Item 3: on Wine 11 Battle.net starts with Store.battlenet.args (Chromium in-process, V8 flags left writable) — say so.
        if engineIsWine11(), Store.battlenet.exes.contains(where: { exe.hasSuffix("/" + $0) }) { parts.append("starts Battle.net with Chromium in-process for Wine 11") }
        // Item 3: Ubisoft Connect's window draws only on a Wine 11 engine (launchCmd starts upc.exe with Chromium in-process); Wine 10: blank.
        let ubiWine10 = ubisoftClient(exe) != nil && !engineIsWine11()
        if ubisoftClient(exe) != nil { parts.append(ubiWine10 ? "Ubisoft Connect's window stays blank on Wine 10 — it draws on the Wine 11 engine (Settings › Engine)" : "starts upc.exe with Chromium in-process, so its window draws") }
        n.note = imps.isEmpty && parts.isEmpty ? "" : "Launch check \(name): " + (imps.isEmpty ? "" : "\(imps.count) DLLs") + (parts.isEmpty ? ", all available" : (imps.isEmpty ? "" : " — ") + parts.joined(separator: "; ")) + "\n"
        n.verbs = winetricks == nil ? [] : verbs
        // Tile light: red = will not start as is, yellow = starts after automatic work or with a caveat, green = ready.
        let red = !unknown.isEmpty || ubiWine10 || (!verbs.isEmpty && winetricks == nil) || n.anticheat?.0 == .red || !plan.missing.isEmpty || parts.contains { $0.contains("brew install") || $0.contains("accept Apple's license") }
        let yellow = !verbs.isEmpty || !n.runtimes.isEmpty || drivers != nil || desktop || n.anticheat != nil || parts.contains { $0.contains("ProtonDB silver") || $0.contains("ProtonDB bronze") || $0.contains("ProtonDB borked") || $0.contains("ProtonDB pending") }
        n.needsDotNet = !dotnet.isEmpty
        n.status = red || dotnet == "bad" ? .red : yellow || dotnet == "pending" ? .yellow : .green
        return n
    }

    // Pre-verification: run the launch check for every tile after a scan, so problems show before anyone clicks Play.
    // Starts after a turn of the run loop so the Library can paint its first frame first (50 tiles: scan was ~0.3 s; verify was the rest).
    func verifyAll() {
        let bottle = selected
        guard FileManager.default.fileExists(atPath: "\(bottlesDir)/\(bottle)/drive_c") else { return }
        Task { @MainActor in
            await Task.yield()
            for p in library {   // every bottle's games: the launch check works per game (item 39)
                noteExeChange(p); readiness[p] = launchNeeds(p); await Task.yield()
            }
            scanAVX(library)   // background disassembly for exes not scanned yet; tiles update as results arrive
            let pfx = "\(bottlesDir)/\(bottle)", fm = FileManager.default
            // Registry values the launch checks no longer want (and pre-ledger ones of programs no longer here) are removed in the background.
            if !cliMode { let wanted = registryWanted(bottle); Task.detached { let r = Model.applyRegistrySweep(bottle, wanted); if !r.isEmpty { await MainActor.run { self.log += "\(bottle): removed \(r.count) registry settings no longer needed:\n" + r.map { "  " + $0 }.joined(separator: "\n") + "\n" } } } }
            // Once per bottle: driver DLLs that older versions copied into system32/syswow64 are moved out (exact-hash copies only).
            if !cliMode, !fm.fileExists(atPath: pfx + "/.driver-copies-checked") {
                fm.createFile(atPath: pfx + "/.driver-copies-checked", contents: nil)
                Task.detached { let moved = Model.cleanDriverCopies(bottle); if !moved.isEmpty { await MainActor.run { self.log += "\(bottle): moved \(moved.count) driver copies out of the system folders:\n" + moved.map { "  " + $0 }.joined(separator: "\n") + "\n" } } }
            }
            // .NET programs in a bottle whose runtime was never probed: run the probe in the background, so their light reflects a real run.
            if !cliMode, !fm.fileExists(atPath: Model.dotnetMarker(pfx)), !fm.fileExists(atPath: Model.dotnetFailMarker(pfx)), programs.contains(where: { exeImports($0).contains("mscoree.dll") }) {
                Task.detached { Model.probeDotNet(pfx); await MainActor.run { if bottle == self.selected { for p in self.programs { self.readiness[p] = self.launchNeeds(p) } } } }
            }
            // Bottle-wide DirectX 12 need: flip the marker, re-check the tiles against the new set, and restart Steam so games started from inside it match.
            // Store clients (Epic's launcher imports d3d12 for its UI) don't count: they run on their own fixed driver set. Neither does
            // steam.exe: it only hosts games, and on Wine 11 its GPU-drawn web views crash on D3DMetal's d3d11/dxgi (black Steam window).
            let needs12 = programs.contains { readiness[$0]?.dx12 == true && storeDrivers($0) == nil && ($0 as NSString).lastPathComponent.lowercased() != "steam.exe" }, marker = dx12Marker(selected)
            if needs12 != FileManager.default.fileExists(atPath: marker), bottle == selected, !cliMode {   // CLI runs see a partial program list; never flip the bottle (and restart Steam) from there
                snapshot("before driver switch: \(needs12 ? "d3dmetal" : "dxmt") for Direct3D 10/11"); backupBottleSaves(selected, "before driver switch")
                if needs12 { FileManager.default.createFile(atPath: marker, contents: nil) } else { try? FileManager.default.removeItem(atPath: marker) }
                log += needs12 ? "A Direct3D 12 game is installed: this bottle now runs d3dmetal for Direct3D 10/11/12.\n" : "No Direct3D 12 game left: back to dxmt for Direct3D 10/11.\n"
                loadSettings(); for p in programs { readiness[p] = launchNeeds(p) }
                requestSteamRestart("games started from Steam get the new driver set")
            }
            // Heal a steam.exe driver-fallback pin left by older builds (games inherit Steam's WINEDLLPATH_*).
            if let steam = programs.first(where: { $0.lowercased().hasSuffix("/steam/steam.exe") }) {
                let before = (try? String(contentsOfFile: optionsPath(steam), encoding: .utf8)) ?? ""
                clearSteamHostDriverFallback(steam)
                let after = (try? String(contentsOfFile: optionsPath(steam), encoding: .utf8)) ?? ""
                if before != after, steamRunning(in: bottle) { requestSteamRestart("Steam no longer pins DXVK over this bottle's Direct3D 12 drivers") }
            }
            // A missing driver folder comes back from the pinned template instead of leaving a red light.
            if driverStatus.1.hasPrefix("missing:"), !busy { restoreMissingDrivers() }
        }
    }

    // Per-program options live in <bottle>/options/<exe>.env as KEY=VALUE lines; the raw text is what the Options… sheet edits.
}
