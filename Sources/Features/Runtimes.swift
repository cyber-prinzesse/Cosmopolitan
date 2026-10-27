import Foundation

// Microsoft runtimes in a bottle: the pinned installers from Microsoft (Components.swift), run with their own silent switches. Used when a
// program imports a DLL that only these runtimes provide, and for the community-fix verbs that name them (instead of winetricks).
enum Runtime: String, CaseIterable, Sendable {
    case vcredist86, vcredist64, directx
    var pin: Pinned { switch self { case .vcredist86: Pins.vcRedist86; case .vcredist64: Pins.vcRedist64; case .directx: Pins.directX } }
}

extension Model {
    // The runtime that provides a DLL a program imports, if it is one of ours. The rule lives in C++ (cosmo_preflight, item 13).
    nonisolated static func runtimeFor(dll: String, is32: Bool) -> Runtime? {
        let n = cosmo_preflight(dll.lowercased(), is32 ? 1 : 0, 0).needs
        if n & UInt32(COSMO_NEED_VCREDIST86) != 0 { return .vcredist86 }
        if n & UInt32(COSMO_NEED_VCREDIST64) != 0 { return .vcredist64 }
        return n & UInt32(COSMO_NEED_DIRECTX) != 0 ? .directx : nil
    }
    // winetricks' own record of what it applied in a bottle (winetricks.log): the last value of each setting verb ("hidewineexports" →
    // "enable"), "" for a plain verb.
    nonisolated static func winetricksApplied(_ prefix: String) -> [String: String] {
        var m: [String: String] = [:]
        for l in ((try? String(contentsOfFile: prefix + "/winetricks.log", encoding: .utf8)) ?? "").split(separator: "\n") {
            let kv = l.split(separator: "=", maxSplits: 1).map(String.init); m[kv[0]] = kv.count == 2 ? kv[1] : ""
        }
        return m
    }
    // CD Projekt's launcher file: the configured game (the "fallback" entry, else the first) and the flag REDprelauncher takes for it.
    nonisolated static func redGame(_ dir: String) -> (exe: String, flag: String)? {
        guard let d = FileManager.default.contents(atPath: dir + "/launcher-configuration.json"), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let list = j["executables"] as? [[String: Any]] else { return nil }
        let pick = list.first { ($0["description"] as? String) == (j["fallback"] as? String) } ?? list.first
        guard let e = pick?["executable"] as? [String: Any], let p = e["directoryPath"] as? String, let f = e["fileName"] as? String else { return nil }
        let exe = dir + "/" + p.replacingOccurrences(of: "\\", with: "/") + "/" + f, desc = pick?["description"] as? String ?? ""
        return FileManager.default.fileExists(atPath: exe) ? (exe, desc.contains("DirectX 12") ? "-dx12" : desc.contains("DirectX 11") ? "-dx11" : "") : nil
    }
    // Item 28: the imports of the DLLs beside a program (its folder, top level, at most 64): an engine DLL can import Direct3D or a runtime
    // the exe itself doesn't. They only add graphics APIs and runtimes, never "missing DLLs" (an unused plugin may import anything).
    nonisolated static func besideImports(_ dir: String) -> Set<String> {
        let dlls = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.lowercased().hasSuffix(".dll") }.sorted().prefix(64)
        return Set(dlls.flatMap { peRead("\(dir)/\($0)").imports })
    }
    // Community-fix (winetricks) verbs that name one of these runtimes.
    nonisolated static func runtimesFor(verb: String) -> [Runtime] {
        let v = verb.lowercased()
        if ["vcrun2015", "vcrun2017", "vcrun2019", "vcrun2022"].contains(v) { return [.vcredist86, .vcredist64] }
        if v.hasPrefix("d3dx9") || v.hasPrefix("d3dx10") || v.hasPrefix("d3dx11") || ["d3dcompiler_43", "xact", "xact_x64", "xinput", "directx9", "dxsdk_jun2010"].contains(v) { return [.directx] }
        return []
    }
    nonisolated static let vcRedistDLLs = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcamp140", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1"]
    nonisolated static func runtimeMarker(_ prefix: String, _ r: Runtime) -> String { prefix + "/.runtime-" + r.rawValue }
    // Microsoft's file, not Wine's builtin stand-in (in every bottle's system folders): Wine stamps "Wine builtin DLL" at offset 64, in the DOS stub.
    nonisolated static func isMicrosoftDLL(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path), let head = try? h.read(upToCount: 256) else { return false }
        try? h.close()
        return head.count >= 128 && head.range(of: Data("Wine builtin DLL".utf8)) == nil
    }

    // Installs the pinned runtime into the bottle. Blocking: call off the main actor.
    @discardableResult nonisolated static func installRuntime(_ r: Runtime, prefix: String, log: @escaping (String) -> Void) -> Bool {
        let fm = FileManager.default
        guard let exe = fetchPinned(r.pin, log: log) else { return false }
        let tmp = prefix + "/drive_c/windows/temp", dst = tmp + "/" + r.pin.file
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dst); try? fm.copyItem(atPath: exe, toPath: dst)   // restricted bottles have no Z:, so it goes onto C:
        log("Installing \(r.pin.name) \(r.pin.version) into the bottle…\n")
        let w = plainWine(prefix)
        switch r {
        case .vcredist86, .vcredist64:
            _ = shell("cd '\(tmp)' && \(w) 'C:\\windows\\temp\\\(r.pin.file)' /install /quiet /norestart >/dev/null 2>&1")
        case .directx:   // the package is a self-extractor: unpack it, then run Microsoft's own DXSETUP silently
            _ = shell("cd '\(tmp)' && \(w) 'C:\\windows\\temp\\\(r.pin.file)' /Q '/T:C:\\windows\\temp\\dxredist' >/dev/null 2>&1 && \(w) 'C:\\windows\\temp\\dxredist\\DXSETUP.exe' /silent >/dev/null 2>&1")
            try? fm.removeItem(atPath: tmp + "/dxredist")
        }
        try? fm.removeItem(atPath: dst)
        // Installed = the runtime's DLL in the system folder is Microsoft's file, not Wine's builtin stand-in.
        let (dir, probe) = r == .vcredist64 ? ("system32", "msvcp140.dll") : r == .vcredist86 ? ("syswow64", "msvcp140.dll") : ("syswow64", "d3dx9_43.dll")
        let ok = isMicrosoftDLL("\(prefix)/drive_c/windows/\(dir)/\(probe)")
        if ok, r == .vcredist86 || r == .vcredist64 {
            // Wine defaults to its builtin CRT DLLs unless DllOverrides names them native,builtin (what winetricks vcrun2015–2022 writes).
            let bottle = (prefix as NSString).lastPathComponent
            for d in vcRedistDLLs where d != "vcruntime140_1" || r == .vcredist64 {
                regSet(bottle, "HKCU\\Software\\Wine\\DllOverrides", d, "native,builtin", exe: "", owner: "bottle")
            }
        }
        if ok { try? "\(r.pin.version)\n".write(toFile: runtimeMarker(prefix, r), atomically: true, encoding: .utf8) }
        log(ok ? "✓ \(r.pin.name) installed (\(dir)\\\(probe) is Microsoft's).\n" : "✗ \(r.pin.name): the installer ran, but \(dir)\\\(probe) is still Wine's own.\n")
        return ok
    }
}
