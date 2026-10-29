import Foundation

// Driver plan, decided from facts instead of rules of thumb:
//  1. what the game uses: its imports (normal + delay-load) plus Direct3D DLL names it loads at runtime, found as strings in the exe and
//     in engine DLLs beside it (UnityPlayer.dll, Bitsquid/Unreal modules, …);
//  2. whether it is a 32- or 64-bit build;
//  3. which installed driver really ships each needed DLL for that architecture (read from engines/renderer/<d>/wine/<arch>-windows).
// Each API goes to the first preferred driver that has it; drivers whose DLLs would overlap are never combined.
struct DriverPlan { var apis: [String]; var is32: Bool; var drivers: [String]; var missing: [String]; var why: [String]; var assigned: [String] = [] }

private let apiDLLs: [(api: String, dlls: [String])] = [
    ("Direct3D 12", ["d3d12.dll"]), ("Direct3D 11", ["d3d11.dll"]), ("Direct3D 10", ["d3d10.dll", "d3d10_1.dll", "d3d10core.dll"]),
    ("Direct3D 9", ["d3d9.dll"]), ("Direct3D 8", ["d3d8.dll"]), ("DirectDraw", ["ddraw.dll"]),
]
private let preference: [String: [String]] = [
    "Direct3D 12": ["d3dmetal"], "Direct3D 11": ["dxmt", "dxvk3", "dxvk", "d3dmetal"], "Direct3D 10": ["dxmt", "dxvk3", "dxvk"],
    "Direct3D 9": ["d9vk", "dxvk3", "dxvk"], "Direct3D 8": ["d9vk", "dxvk3"], "DirectDraw": ["cnc_ddraw"],
]

func rendererDLLs(_ d: String, is32: Bool) -> Set<String> {   // an unusable driver provides nothing, so plans and serves() look past it
    guard driverUsable(d) else { return [] }
    return Set(((try? FileManager.default.contentsOfDirectory(atPath: "\(driversDir)/\(d)/wine/\(is32 ? "i386" : "x86_64")-windows")) ?? []).map { $0.lowercased() })
}

extension Model {
    // File cues that a game ships Direct3D 12 (Agility SDK / DXIL). These alone may add d3d12.dll to the launch-check imports
    // (bypassing the DX11-default guard). Adapted from abduzeedo/mapc-engine GraphicsProbe.swift (Apache-2.0; THIRD_PARTY_NOTICES.md).
    // The bare string D3D12CreateDevice is handled only in graphicsAPIs — Witcher 3's DX11 exe contains it and must stay on DXMT.
    func runtimeShipsD3D12Files(_ exe: String) -> Bool {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: exe)
        let key = "\(attrs?[.size] as? Int ?? 0)|\(Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        let cache = "\(bottlesDir)/\(bottleOf(exe))/options/.dx12-\((exe as NSString).lastPathComponent)"
        if let c = try? String(contentsOfFile: cache, encoding: .utf8), c.hasPrefix(key + "\n") {
            return c.components(separatedBy: "\n").dropFirst().first == "1"
        }
        let yes = Model.probeD3D12Files(exe)
        try? fm.createDirectory(atPath: (cache as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "\(key)\n\(yes ? "1" : "0")\n".write(toFile: cache, atomically: true, encoding: .utf8)
        return yes
    }
    nonisolated static func probeD3D12Files(_ exe: String) -> Bool {
        let fm = FileManager.default, dir = (exe as NSString).deletingLastPathComponent
        guard let en = fm.enumerator(atPath: dir) else { return false }
        for case let p as String in en {   // stay inside this program: never a Steam library or Unreal Engine tree
            // cef: Chromium ships its own dxil.dll for its GPU process (Steam's bin/cef/cef.win64): a browser, not a Direct3D 12 game.
            if en.level > 4 || p.hasPrefix("Engine/") || p.hasPrefix("steamapps") || (p as NSString).lastPathComponent.lowercased() == "cef" { en.skipDescendants(); continue }
            let name = (p as NSString).lastPathComponent.lowercased()
            let folder = ((p as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
            if name == "d3d12core.dll", folder == "d3d12" { return true }   // UE5: Binaries/Win64/D3D12/D3D12Core.dll
            if name == "dxil.dll" || (name.hasPrefix("dxilconv") && name.hasSuffix(".dll")) { return true }
        }
        return false
    }

    // Graphics APIs the program uses. The string scan is cached per exe (keyed by size + date) because it reads tens of MB.
    func graphicsAPIs(_ exe: String, imports: [String]) -> [String] {
        let fm = FileManager.default, dir = (exe as NSString).deletingLastPathComponent
        let attrs = try? fm.attributesOfItem(atPath: exe)
        let key = "\(attrs?[.size] as? Int ?? 0)|\(Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        let cache = "\(bottlesDir)/\(selected)/options/.gfx-\((exe as NSString).lastPathComponent)"
        var found = Set<String>()
        if let c = try? String(contentsOfFile: cache, encoding: .utf8), c.hasPrefix(key + "\n") {
            found = Set(c.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty })
        } else {
            var files = [exe]
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.lowercased().hasSuffix(".dll") {
                let p = "\(dir)/\(f)", s = (try? fm.attributesOfItem(atPath: p))?[.size] as? Int ?? 0
                if s > 1_000_000, s < 200_000_000, !apiDLLs.contains(where: { $0.dlls.contains(f.lowercased()) }) { files.append(p) }   // engine modules, not shipped D3D copies
            }
            // Unity keeps the engine (and D3D12CreateDevice) in UnityPlayer.dll even when it is under 1 MB.
            let unity = dir + "/UnityPlayer.dll"
            if fm.fileExists(atPath: unity), !files.contains(unity) { files.append(unity) }
            let createDevice = Data("D3D12CreateDevice".utf8)
            for f in files.prefix(12) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: f), options: .alwaysMapped) else { continue }
                for (api, dlls) in apiDLLs where !found.contains(api) {
                    for d in dlls {
                        let stem = (d as NSString).deletingPathExtension
                        let variants = [d, d.uppercased(), stem.uppercased() + ".dll", stem.capitalized + ".dll"]
                        if variants.contains(where: { v in data.range(of: Data(v.utf8)) != nil || data.range(of: v.data(using: .utf16LittleEndian)!) != nil }) { found.insert(api); break }
                    }
                }
                // mapc-engine: D3D12CreateDevice means the binary can load DX12; does not touch imports (DX11+string stays on DXMT).
                if !found.contains("Direct3D 12"), data.range(of: createDevice) != nil { found.insert("Direct3D 12") }
            }
            try? fm.createDirectory(atPath: (cache as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? ([key] + found.sorted()).joined(separator: "\n").write(toFile: cache, atomically: true, encoding: .utf8)
        }
        // Engines that can load either D3D11 or D3D12 at runtime (Unity, Unreal 4, Witcher 3 DX11) default to D3D11; D3D12 counts
        // only when imported (or when Agility/DXIL files made the launch check add d3d12.dll to the imports).
        if found.contains("Direct3D 11"), !imports.contains("d3d12.dll") { found.remove("Direct3D 12") }
        for (api, dlls) in apiDLLs where dlls.contains(where: imports.contains) { found.insert(api) }
        return apiDLLs.map { $0.api }.filter(found.contains)
    }

    func driverPlan(_ exe: String, imports: [String], prefer: String? = nil) -> DriverPlan {
        let is32 = peRead(exe).info.machine == 0x14c
        let apis = graphicsAPIs(exe, imports: imports)
        let installed = installedDrivers().filter { $0 != "d3dmetal" || (d3dmetalOK && d3dmetalInstalled()) }
        var chosen: [String] = [], provided = Set<String>(), missing: [String] = [], why: [String] = [], assigned: [String] = []
        func add(_ d: String) -> Bool {
            let dlls = rendererDLLs(d, is32: is32)
            guard !dlls.isEmpty, provided.isDisjoint(with: dlls.subtracting(["winemetal.dll", "nvapi64.dll", "nvngx.dll"])) else { return false }
            chosen.append(d); provided.formUnion(dlls); return true
        }
        for (api, dlls) in apiDLLs where apis.contains(api) {
            if dlls.contains(where: provided.contains) { assigned.append(api); continue }   // already served by a driver picked for a newer API
            var order = preference[api] ?? []
            if let p = prefer, order.contains(p) { order.removeAll { $0 == p }; order.insert(p, at: 0) }   // Highball's pick first, if it can serve
            if let d = order.first(where: { installed.contains($0) && !rendererDLLs($0, is32: is32).isDisjoint(with: dlls) && add($0) }) {
                why.append("\(api) → \(d)"); assigned.append(api)
            } else if ["DirectDraw", "Direct3D 8", "Direct3D 9"].contains(api) {
                why.append("\(api) → Wine's own")   // wined3d covers these well enough; no driver is not a failure
            } else {
                missing.append(api)
                why.append("\(api) → no installed driver has it for \(is32 ? "32" : "64")-bit" + (api == "Direct3D 12" && !is32 ? (d3dmetalInstalled() ? " (accept D3DMetal's license)" : " (install D3DMetal)") : ""))
            }
        }
        // Older APIs a game may still load at runtime (menus, videos, launchers): add their drivers when they do not overlap.
        for extra in ["d9vk", "cnc_ddraw"] where installed.contains(extra) && !chosen.contains(extra) { _ = add(extra) }
        return DriverPlan(apis: apis, is32: is32, drivers: chosen, missing: missing, why: why, assigned: assigned)
    }

    // Does a driver set serve every API of the plan for this architecture (so no switch or Steam restart is needed)?
    func serves(_ set: [String], _ plan: DriverPlan) -> Bool {
        let have = set.reduce(into: Set<String>()) { $0.formUnion(rendererDLLs($1, is32: plan.is32)) }
        return apiDLLs.filter { plan.assigned.contains($0.api) }.allSatisfy { $0.dlls.contains(where: have.contains) }
    }
}
