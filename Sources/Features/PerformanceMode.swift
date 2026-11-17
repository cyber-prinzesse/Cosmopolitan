import Foundation

// Performance mode (bottle toggle, COSMO_PERF=1): Unreal games' GameUserSettings.ini get the costly scalability groups capped —
// Lumen GI/reflections off (≤1), shading/foliage/shadows ≤2, and TSR on when the game renders below 100 %. Works for games Steam
// starts too, because it edits the files rather than the launch. The first edit keeps a copy (.cosmo-perf-backup); off restores it.
extension Model {
    static let perfCaps = ["sg.GlobalIlluminationQuality": 1, "sg.ReflectionQuality": 1, "sg.ShadingQuality": 2,
                           "sg.FoliageQuality": 2, "sg.ShadowQuality": 2]

    // UE4 writes Saved/Config/WindowsNoEditor, UE5 Saved/Config/Windows.
    func unrealSettingsFiles(_ bottle: String) -> [String] {
        let users = "\(bottlesDir)/\(bottle)/drive_c/users", fm = FileManager.default
        var out: [String] = []
        for u in (try? fm.contentsOfDirectory(atPath: users)) ?? [] {
            let local = "\(users)/\(u)/AppData/Local"
            for g in (try? fm.contentsOfDirectory(atPath: local)) ?? [] {
                for d in ["Windows", "WindowsNoEditor"] {
                    let f = "\(local)/\(g)/Saved/Config/\(d)/GameUserSettings.ini"
                    if fm.fileExists(atPath: f) { out.append(f) }
                }
            }
        }
        return out
    }

    static func perfTuned(_ ini: String) -> String {
        var lines = ini.components(separatedBy: "\n")
        let res = lines.first { $0.hasPrefix("sg.ResolutionQuality=") }.flatMap { Double($0.split(separator: "=")[1].trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 100   // the game writes CRLF
        for (i, l) in lines.enumerated() {
            let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, let v = Int(kv[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let cr = l.hasSuffix("\r") ? "\r" : ""
            if let cap = perfCaps[kv[0]], v > cap { lines[i] = "\(kv[0])=\(cap)\(cr)" }
            if kv[0] == "sg.AntiAliasingQuality", v < 2, res < 100 { lines[i] = "\(kv[0])=2\(cr)" }
        }
        return lines.joined(separator: "\n")
    }

    // Accelerator (bottle toggle): MetalFX upscaling in both Metal backends. D3DMetal turns a game's DLSS option into MetalFX temporal
    // upscaling; DXMT renders Direct3D 11 at 2/3 and MetalFX-upscales. A DXMT_CONFIG set by hand or by the battery saver is left alone.
    static let acceleratorDXMT = "d3d11.metalSpatialUpscaleFactor=1.5"
    func setAccelerator(_ on: Bool) {
        envSet("D3DM_ENABLE_METALFX", on ? "1" : nil)
        let cur = launchEnvRaw()["DXMT_CONFIG"]
        if on, cur == nil { envSet("DXMT_CONFIG", Model.acceleratorDXMT) }
        if !on, cur == Model.acceleratorDXMT { envSet("DXMT_CONFIG", nil) }
    }

    // MacBook Air mode (bottle toggle, COSMO_AIR=1): one switch for an 8 GB Air. Emulated display modes (any resolution in fullscreen,
    // incl. 1280x800), Unreal games at 1280x800 / 75 % render scale / TSR / 30 fps with the Air profile and Engine.ini cuts (virtual
    // shadows, Lumen, volumetrics off, 1 GB texture pool), native Visual C++ runtimes (games' "component required" check reads their
    // version, Wine's builtins have none), D3DMetal's own 30 fps cap where it has one. Off restores each file from its backup.
    static let airCaps = ["sg.ResolutionQuality": "75", "sg.ViewDistanceQuality": "1", "sg.AntiAliasingQuality": "2", "sg.ShadowQuality": "1",
        "sg.GlobalIlluminationQuality": "1", "sg.ReflectionQuality": "1", "sg.PostProcessQuality": "1", "sg.TextureQuality": "1",
        "sg.EffectsQuality": "1", "sg.FoliageQuality": "1", "sg.ShadingQuality": "1", "ResolutionSizeX": "1280", "ResolutionSizeY": "800",
        "LastUserConfirmedResolutionSizeX": "1280", "LastUserConfirmedResolutionSizeY": "800", "FullscreenMode": "0",
        "LastConfirmedFullscreenMode": "0", "PreferredFullscreenMode": "0", "FrameRateLimit": "30.000000"]
    static let airMark = "; Cosmopolitan MacBook Air mode"
    static let airEngineIni = "[SystemSettings]\r\n\(airMark) (removed when the mode is turned off)\r\n" + ["r.Streaming.PoolSize=1024",
        "r.Streaming.LimitPoolSizeToVRAM=1", "r.Shadow.Virtual.Enable=0", "r.DynamicGlobalIlluminationMethod=0", "r.ReflectionMethod=0",
        "r.Lumen.DiffuseIndirect.Allow=0", "r.Lumen.Reflections.Allow=0", "r.VolumetricFog=0", "r.VolumetricCloud=0", "r.SSR.Quality=0",
        "r.AmbientOcclusionLevels=0", "r.ContactShadows=0", "r.MotionBlurQuality=0", "r.DepthOfFieldQuality=0", "r.LensFlareQuality=0",
        "r.SceneColorFringeQuality=0", "r.BloomQuality=1", "r.Nanite.MaxPixelsPerEdge=4", "r.ViewDistanceScale=0.6",
        "foliage.DensityScale=0.5", "grass.DensityScale=0.5", "r.MaxAnisotropy=4"].map { $0 + "\r\n" }.joined()
    static let vcRuntimes = ["msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcruntime140",
                             "vcruntime140_1", "concrt140", "vcomp140"]

    static func airTuned(_ ini: String) -> String {
        ini.components(separatedBy: "\n").map { l in
            guard let k = l.split(separator: "=", maxSplits: 1).first.map(String.init), let v = airCaps[k], l.contains("=") else { return l }
            return "\(k)=\(v)" + (l.hasSuffix("\r") ? "\r" : "")
        }.joined(separator: "\n")
    }

    @discardableResult func applyAirMode(_ on: Bool, bottle: String) -> String {
        let fm = FileManager.default
        var out = ""
        if on {
            Model.regSet(bottle, "HKCU\\Software\\Wine\\X11 Driver", "EmulateModeset", "y", exe: "", owner: "air")
            for d in Model.vcRuntimes { Model.regSet(bottle, "HKCU\\Software\\Wine\\DllOverrides", d, "native,builtin", exe: "", owner: "air") }
        } else {
            _ = shell("\(plainWine("\(bottlesDir)/\(bottle)")) reg delete \(shq("HKCU\\Software\\Wine\\X11 Driver")) /v EmulateModeset /f >/dev/null 2>&1")
        }
        if on, d3dmetalFrameCap() { envSet("D3DM_MAX_FPS", "30") } else if !on, launchEnvRaw()["D3DM_MAX_FPS"] == "30" { envSet("D3DM_MAX_FPS", nil) }
        for f in unrealSettingsFiles(bottle) {
            let game = f.components(separatedBy: "/AppData/Local/").last?.components(separatedBy: "/").first ?? f
            let backup = f + ".cosmo-air-backup", ini = (f as NSString).deletingLastPathComponent + "/Engine.ini", iniBackup = ini + ".cosmo-air-backup"
            if on {
                guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
                if !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: f, toPath: backup) }
                try? Model.airTuned(t).write(toFile: f, atomically: true, encoding: .utf8)
                let cur = (try? String(contentsOfFile: ini, encoding: .utf8)) ?? ""
                if fm.fileExists(atPath: ini), !cur.contains(Model.airMark), !fm.fileExists(atPath: iniBackup) { try? fm.copyItem(atPath: ini, toPath: iniBackup) }
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ini); try? fm.removeItem(atPath: ini)
                try? Model.airEngineIni.write(toFile: ini, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ini)   // Unreal deletes config files it thinks are unneeded
                out += "MacBook Air mode: \(game) at 1280x800, 30 fps, Air profile.\n"
            } else {
                if fm.fileExists(atPath: backup) { try? fm.removeItem(atPath: f); try? fm.moveItem(atPath: backup, toPath: f) }
                if ((try? String(contentsOfFile: ini, encoding: .utf8)) ?? "").contains(Model.airMark) {
                    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ini); try? fm.removeItem(atPath: ini)
                }
                if fm.fileExists(atPath: iniBackup) { try? fm.moveItem(atPath: iniBackup, toPath: ini) }
                out += "MacBook Air mode off: \(game) settings restored.\n"
            }
        }
        return out
    }

    // --toggles-selftest <bottle>: every toggle on, checked, off, checked against the state before. Changes the bottle while it runs,
    // so it is meant for a clone of a real bottle.
    func togglesSelfTest() -> String {
        let b = selected, fm = FileManager.default
        var out = "toggles self-test on bottle \(b)\n", ok = true
        func check(_ c: Bool, _ what: String) { out += (c ? "  ok    " : "  FAIL  ") + what + "\n"; if !c { ok = false } }
        func read(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
        let files = unrealSettingsFiles(b), inis = files.map { ($0 as NSString).deletingLastPathComponent + "/Engine.ini" }
        let before = files.map(read), iniBefore = inis.map(read), env0 = launchEnvRaw()
        let x11 = "HKCU\\Software\\Wine\\X11 Driver", dll = "HKCU\\Software\\Wine\\DllOverrides"
        check(!files.isEmpty, "Unreal settings files found: \(files.count)")

        _ = applyPerformanceMode(true, bottle: b)
        for f in files { let t = read(f) ?? ""; check(!t.isEmpty && t == Model.perfTuned(t), "Performance mode: caps applied (\(f.components(separatedBy: "/Local/").last ?? f))") }
        _ = applyPerformanceMode(false, bottle: b)
        check(files.map(read) == before, "Performance mode off: every settings file restored")

        _ = applyAirMode(true, bottle: b)
        check(Model.regGet(b, x11, "EmulateModeset") == "y", "Air mode: emulated display modes on")
        check(Model.vcRuntimes.allSatisfy { Model.regGet(b, dll, $0) == "native,builtin" }, "Air mode: native Visual C++ runtimes")
        for (f, ini) in zip(files, inis) {
            let t = read(f) ?? ""
            check(t.contains("ResolutionSizeX=1280") && t == Model.airTuned(t), "Air mode: 1280x800, 30 fps profile")
            check((read(ini) ?? "").contains(Model.airMark) && !fm.isWritableFile(atPath: ini), "Air mode: Engine.ini written and locked")
        }
        _ = applyAirMode(false, bottle: b)
        check(Model.regGet(b, x11, "EmulateModeset") == nil, "Air mode off: emulated display modes off")
        check(files.map(read) == before, "Air mode off: every settings file restored")
        check(inis.map(read) == iniBefore, "Air mode off: Engine.ini back as it was")

        setAccelerator(true)
        let e1 = launchEnvRaw()
        check(e1["D3DM_ENABLE_METALFX"] == "1", "Accelerator: DLSS-to-MetalFX on")
        check(env0["DXMT_CONFIG"] != nil || e1["DXMT_CONFIG"] == Model.acceleratorDXMT, "Accelerator: DXMT MetalFX upscaling on")
        setAccelerator(false)
        let e2 = launchEnvRaw()
        check(e2["D3DM_ENABLE_METALFX"] == nil && e2["DXMT_CONFIG"] == env0["DXMT_CONFIG"], "Accelerator off: settings back as they were")
        return out + (ok ? "toggles self-test PASSED\n" : "toggles self-test FAILED\n")
    }

    // Returns what changed, for the log.
    @discardableResult func applyPerformanceMode(_ on: Bool, bottle: String) -> String {
        let fm = FileManager.default
        var out = ""
        for f in unrealSettingsFiles(bottle) {
            let backup = f + ".cosmo-perf-backup", game = f.components(separatedBy: "/AppData/Local/").last?.components(separatedBy: "/").first ?? f
            if on {
                guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
                let tuned = Model.perfTuned(t)
                if tuned == t { continue }
                if !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: f, toPath: backup) }
                try? tuned.write(toFile: f, atomically: true, encoding: .utf8)
                out += "Performance mode: \(game) tuned (Lumen off, lighter shading).\n"
            } else if fm.fileExists(atPath: backup) {
                try? fm.removeItem(atPath: f); try? fm.moveItem(atPath: backup, toPath: f)
                out += "Performance mode off: \(game) settings restored.\n"
            }
        }
        return out
    }
}
