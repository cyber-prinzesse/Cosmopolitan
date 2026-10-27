import SwiftUI

extension Model {
    func tuneUnreal(_ exe: String) -> String? {
        // Disabled 2026-10-22: writing a partial [ScalabilityGroups] section made Unreal fall back to defaults for every other group
        // (native resolution, no upscaler) and tanked Dawnwalker to ~10 fps. Graphics settings belong to the game's own menu.
        return nil
        guard exe.contains("/Binaries/Win64/") else { return nil }
        let project = ((exe as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "-Win64-Shipping", with: "")
        let ini = "\(bottlesDir)/\(selected)/drive_c/users/\(NSUserName())/AppData/Local/\(project)/Saved/Config/Windows/GameUserSettings.ini"
        // The game rewrites this file and drops comments, so the "done once" marker is a sidecar file, not a line in the ini.
        let marker = "\(bottlesDir)/\(selected)/options/.tuned-\(project)"
        guard var s = try? String(contentsOfFile: ini, encoding: .utf8), !FileManager.default.fileExists(atPath: marker) else { return nil }
        s = s.replacingOccurrences(of: "bUseVSync=True", with: "bUseVSync=False")   // some games re-assert their own VSync setting; harmless if so
        if !s.contains("[ScalabilityGroups]") { s += "\n[ScalabilityGroups]\nsg.ShadowQuality=1\nsg.GlobalIlluminationQuality=1\nsg.ReflectionQuality=1\n" }
        // Fullscreen mode is left alone: under the Mac driver presentation is composited either way (checked with the Metal HUD), so exclusive mode buys nothing.
        try? s.write(toFile: ini, atomically: true, encoding: .utf8)
        // Texture streaming pool: Unreal sizes it from the "VRAM" the translation layer reports, which undersells unified memory.
        // Give it ~1/4.5 of RAM (7 GB on a 32 GB Mac) through the per-user Engine.ini override, which the game does not rewrite.
        let pool = max(3000, Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) * 2 / 9)
        let eng = (ini as NSString).deletingLastPathComponent + "/Engine.ini"
        var e = (try? String(contentsOfFile: eng, encoding: .utf8)) ?? ""
        if !e.contains("r.Streaming.PoolSize") { e += "\n[SystemSettings]\nr.Streaming.PoolSize=\(pool)\n"; try? e.write(toFile: eng, atomically: true, encoding: .utf8) }
        try? FileManager.default.createDirectory(atPath: (marker as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker, contents: nil)
        return "Tuned \(project): VSync off, shadows/GI/reflections start at Medium, \(pool / 1000) GB texture pool (change freely in the game's menu).\n"
    }

    // Steam overlay hooks the game's presentation and costs frames under translation; switch it off in Steam's config while Steam is down,
    // and move GameOverlayRenderer(64).dll aside so modern Steam cannot inject it via full-path LoadLibraryW (which bypasses Wine DllOverrides).
    func tuneSteam() {
        let steamDir = "\(bottlesDir)/\(selected)/drive_c/Program Files (x86)/Steam", fm = FileManager.default
        let cfgs = (try? fm.contentsOfDirectory(atPath: "\(steamDir)/userdata")) ?? []
        for u in cfgs {
            let p = "\(steamDir)/userdata/\(u)/config/localconfig.vdf"
            guard var s = try? String(contentsOfFile: p, encoding: .utf8), !s.contains("\"EnableGameOverlay\""), let r = s.range(of: "\"system\"\n\t{\n") else { continue }
            s.insert(contentsOf: "\t\t\"EnableGameOverlay\"\t\t\"0\"\n", at: r.upperBound)
            try? s.write(toFile: p, atomically: true, encoding: .utf8)
            logToFile("Steam overlay switched off\n"); log += "Steam overlay switched off (costs frames under translation).\n"
        }
        for dll in ["GameOverlayRenderer64.dll", "GameOverlayRenderer.dll"] where fm.fileExists(atPath: "\(steamDir)/\(dll)") {
            try? fm.removeItem(atPath: "\(steamDir)/\(dll).disabled")
            try? fm.moveItem(atPath: "\(steamDir)/\(dll)", toPath: "\(steamDir)/\(dll).disabled")
        }
    }

    // Run with everything prepare() found: runtimes first (winetricks), Steam restart if the driver set changed, then the program.
}
