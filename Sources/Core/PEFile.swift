import SwiftUI

// DLL names an .exe imports (PE import directory), lowercased. Drives the launch check.
// Native (Sources/Native/pe.cpp): normal AND delay-load imports, so a game that delay-loads d3d12 or xinput is seen too.
func exeImports(_ path: String) -> [String] { peRead(path).imports }
// Delay-load-only imports (loaded at runtime from the program's own folders): optional, so not counted as "missing DLLs".
func exeDelayImports(_ path: String) -> [String] { peRead(path).delay }
// Executable era: "dos" (plain MZ), "win16" (NE), or "pe" with the subsystem major version the linker stamped
// (4 = Windows 95/NT4 era, 5 = 2000/XP, 6+ = Vista and later). Old ones get a virtual desktop so fullscreen mode switches don't fight Retina.
// `linker` is OptionalHeader.MajorLinkerVersion: 6 = Visual C++ 6 (1998), 7–9 = VC 2002–2008, 10+ = 2010 and later, 2 = GNU ld (MinGW),
// which stamps old subsystem numbers on brand-new programs, so the era rules ignore it.
func exeEra(_ path: String) -> (kind: String, subsystem: Int, linker: Int) {
    let i = peRead(path).info
    switch i.kind { case 1: return ("dos", 0, 0); case 2: return ("win16", 3, 0); case 3: return ("pe", Int(i.subsystem_major), Int(i.linker_major)); default: return ("", 0, 0) }
}

// DLLs the engine provides itself; anything imported that is neither here, nor beside the exe, nor in system32 is really missing.
let builtinDLLs: Set<String> = {
    let b = ((wineBin as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/lib/wine"
    return Set(["x86_64-windows", "i386-windows"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: "\(b)/\($0)")) ?? [] }.map { $0.lowercased() })
}()
// Missing DLL -> winetricks verb that supplies it. ponytail: only runtimes Wine has no builtin for; extend when a game asks for more.
let depVerbs = ["physxloader.dll": "physx", "physxloader64.dll": "physx", "xlive.dll": "gfw",
                "msvcr71.dll": "vcrun2003", "msvcp71.dll": "vcrun2003", "mfc42.dll": "mfc42", "vb6stkit.dll": "vb6run"]
let winetricks = ["/opt/homebrew/bin/winetricks", "/usr/local/bin/winetricks"].first { FileManager.default.fileExists(atPath: $0) }

// Extract the main icon from a Windows .exe (PE resources) and return it as an NSImage.
func exeIcon(_ path: String) -> NSImage? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), d.count > 0x100 else { return nil }
    func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o+1]) << 8 : 0 }
    func u32(_ o: Int) -> Int { o + 4 <= d.count ? u16(o) | u16(o+2) << 16 : 0 }
    let pe = u32(0x3C)
    guard u32(pe) == 0x4550 else { return nil }
    let nSec = u16(pe + 6), opt = pe + 24
    let plus = u16(opt) == 0x20b
    let resRVA = u32(opt + (plus ? 112 : 96) + 16)
    guard resRVA != 0 else { return nil }
    let secs = opt + u16(pe + 20)
    func off(_ rva: Int) -> Int? {
        for i in 0..<nSec { let s = secs + i * 40
            let va = u32(s + 12), sz = max(u32(s + 8), u32(s + 16))
            if rva >= va && rva < va + sz { return rva - va + u32(s + 20) } }
        return nil
    }
    guard let root = off(resRVA) else { return nil }
    // entries of a resource directory: (id, offset, isDir)
    func entries(_ dir: Int) -> [(Int, Int, Bool)] {
        let n = u16(dir + 12) + u16(dir + 14)
        return (0..<n).map { i in let e = dir + 16 + i * 8; let o = u32(e + 4)
            return (u32(e), root + (o & 0x7fffffff), o & 0x80000000 != 0) }
    }
    // resources of a type: [id: data], first language only
    func res(_ type: Int) -> [Int: Data] {
        var out: [Int: Data] = [:]
        guard let t = entries(root).first(where: { $0.0 == type && $0.2 }) else { return out }
        for n in entries(t.1) where n.2 {
            guard let l = entries(n.1).first, !l.2, let o = off(u32(l.1)) else { continue }
            let sz = u32(l.1 + 4)
            if o + sz <= d.count { out[n.0] = d.subdata(in: o..<o + sz) }
        }
        return out
    }
    let icons = res(3)
    guard let grp = res(14).sorted(by: { $0.key < $1.key }).first?.value, grp.count >= 6 else { return nil }
    func g16(_ o: Int) -> Int { Int(grp[o]) | Int(grp[o+1]) << 8 }
    var best: (w: Int, bits: Int, id: Int)?
    for i in 0..<g16(4) where 6 + i * 14 + 14 <= grp.count {
        let e = 6 + i * 14
        let w = grp[e] == 0 ? 256 : Int(grp[e]), bits = g16(e + 6), id = g16(e + 12)
        if icons[id] != nil, best == nil || (w, bits) > (best!.w, best!.bits) { best = (w, bits, id) }
    }
    guard let b = best, let img = icons[b.id] else { return nil }
    var ico = Data([0, 0, 1, 0, 1, 0])
    ico.append(Data([UInt8(b.w == 256 ? 0 : b.w), UInt8(b.w == 256 ? 0 : b.w), 0, 0, 1, 0, UInt8(b.bits & 255), UInt8(b.bits >> 8)]))
    withUnsafeBytes(of: UInt32(img.count).littleEndian) { ico.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(22).littleEndian) { ico.append(contentsOf: $0) }
    ico.append(img)
    return NSImage(data: ico)
}
