import Foundation

// One Dock icon for Steam: steam.exe has no window of its own, but Wine makes every program that ever shows a window a regular
// Dock app, so Steam sat in the Dock twice. Bottles mark such programs with Mac Driver › NoDockIcon (see healSteamDockIcon); the
// engine's Mac driver honours it through cosmo_nodock.dylib (EngineAddon/), loaded by one extra LC_LOAD_DYLIB in winemac.so.
// The driver itself can't be rebuilt: Sikarugir's is CrossOver-based and D3DMetal/DXMT use its macdrv_functions. Done once per
// engine; files are swapped in by rename, so running programs keep what they mapped. The original stays as winemac.so.orig-before-nodock.
extension Model {
    nonisolated static let noDockAddon = "cosmo_nodock.dylib"

    // Whether this Mach-O (64-bit, little-endian) already loads @loader_path/cosmo_nodock.dylib.
    nonisolated static func machoLoads(_ d: Data, _ dylib: String) -> Bool { machoLoadCommands(d)?.dylibs.contains(dylib) ?? false }

    nonisolated static func machoLoadCommands(_ d: Data) -> (end: Int, firstSection: Int, dylibs: [String])? {
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) : 0 }
        guard d.count > 32, u32(0) == 0xfeedfacf else { return nil }
        let ncmds = u32(16), end = 32 + u32(20)
        var off = 32, first = d.count, dylibs: [String] = []
        for _ in 0..<ncmds {
            let cmd = u32(off), size = u32(off + 4)
            guard size >= 8, off + size <= d.count else { return nil }
            if cmd == 0x19 { for i in 0..<u32(off + 64) { let s = u32(off + 72 + i * 80 + 48); if s > 0 { first = min(first, s) } } }   // LC_SEGMENT_64 section offsets
            if cmd == 0xc, let n = String(data: d.subdata(in: off + u32(off + 8)..<off + size), encoding: .utf8) {   // LC_LOAD_DYLIB
                dylibs.append(n.components(separatedBy: "\0")[0])
            }
            off += size
        }
        return (end, first, dylibs)
    }

    // A copy of `d` with an LC_LOAD_DYLIB for `dylib` appended to the load commands (nil: no room in the header padding).
    nonisolated static func machoAddingDylib(_ d: Data, _ dylib: String) -> Data? {
        guard let lc = machoLoadCommands(d) else { return nil }
        let name = Array(dylib.utf8) + [0], size = (24 + name.count + 7) / 8 * 8
        guard lc.firstSection - lc.end >= size, d.subdata(in: lc.end..<lc.end + size).allSatisfy({ $0 == 0 }) else { return nil }
        var cmd = Data()
        for v: UInt32 in [0xc, UInt32(size), 24, 2, 0x10000, 0x10000] { withUnsafeBytes(of: v.littleEndian) { cmd.append(contentsOf: $0) } }
        cmd.append(contentsOf: name); cmd.append(Data(count: size - cmd.count))
        var out = d
        out.replaceSubrange(lc.end..<lc.end + size, with: cmd)
        func put(_ o: Int, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.replaceSubrange(o..<o + 4, with: $0) } }
        let ncmds = d.subdata(in: 16..<20).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, sizeofcmds = d.subdata(in: 20..<24).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        put(16, ncmds + 1); put(20, sizeofcmds + UInt32(size))
        return out
    }

    // Puts the add-on into `engine` (…/wswine.bundle) and makes its winemac.so load it. Returns a log line ("" when nothing to do).
    @discardableResult nonisolated static func installNoDockAddon(_ engine: String, addon: String = (Bundle.main.resourcePath ?? "") + "/cosmo_nodock.dylib") -> String {
        let fm = FileManager.default, unix = engine + "/lib/wine/x86_64-unix", mac = unix + "/winemac.so", dst = unix + "/" + noDockAddon
        guard fm.fileExists(atPath: addon), let orig = fm.contents(atPath: mac) else { return "" }
        if !fm.contentsEqual(atPath: addon, andPath: dst) {
            let t = dst + ".new"; try? fm.removeItem(atPath: t)
            guard (try? fm.copyItem(atPath: addon, toPath: t)) != nil, rename(t, dst) == 0 else { return "✗ One Dock icon for Steam: couldn't copy \(noDockAddon) into the engine\n" }
        }
        let ref = "@loader_path/" + noDockAddon
        if machoLoads(orig, ref) { return "" }
        let t = mac + ".nodock-tmp"; try? fm.removeItem(atPath: t)
        guard fm.createFile(atPath: t, contents: orig) else { return "✗ One Dock icon for Steam: engine folder not writable\n" }
        _ = shell("codesign --remove-signature '\(t)' 2>/dev/null")
        guard let unsigned = fm.contents(atPath: t), let patched = machoAddingDylib(unsigned, ref), fm.createFile(atPath: t, contents: patched) else {
            try? fm.removeItem(atPath: t); return "✗ One Dock icon for Steam: this engine's Mac driver has no room for the add-on; left as is\n"
        }
        _ = shell("chmod 755 '\(t)'; codesign --force -s - '\(t)' 2>/dev/null")
        guard let signed = fm.contents(atPath: t), machoLoads(signed, ref) else { try? fm.removeItem(atPath: t); return "✗ One Dock icon for Steam: patching the Mac driver failed; left as is\n" }
        if !fm.fileExists(atPath: mac + ".orig-before-nodock") { try? fm.copyItem(atPath: mac, toPath: mac + ".orig-before-nodock") }
        guard rename(t, mac) == 0 else { try? fm.removeItem(atPath: t); return "✗ One Dock icon for Steam: couldn't replace the Mac driver\n" }
        return "One Dock icon for Steam: engine's Mac driver now honours NoDockIcon.\n"
    }
}
