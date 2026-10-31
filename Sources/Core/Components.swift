import Foundation
import CryptoKit

// Everything Cosmopolitan downloads is pinned: exact version, official URL, SHA-256, licence and source. Nothing is installed unless the
// downloaded file's hash matches. The full component list with sources is in docs/components.md.
struct Pinned: Sendable { let name, version, file, url, sha256, license, source: String }

enum Pins {
    // WineHQ publishes no checksum file; this hash is of the WineHQ file, and the release asset on the Wine Mono project's own GitHub
    // has the same bytes (both downloaded and compared on 2026-10-22).
    static let wineMono = Pinned(name: "Wine Mono", version: "9.4.0", file: "wine-mono-9.4.0-x86.msi",
        url: "https://dl.winehq.org/wine/wine-mono/9.4.0/wine-mono-9.4.0-x86.msi",
        sha256: "cf6173ae94b79e9de13d9a74cdb2560a886fc3d271f9489acb1cfdbd961cacb2",
        license: "MIT, with bundled components under their own licences", source: "WineHQ (same bytes as github.com/madewokherd/wine-mono, release wine-mono-9.4.0)")

    // Microsoft runtimes, downloaded from Microsoft at setup and installed into a bottle when a program needs them; never bundled.
    // Microsoft's versioned URLs carry the file's SHA-256 in the path, and it matches the pin.
    static let vcRedist86 = Pinned(name: "Microsoft Visual C++ v14 Redistributable (x86)", version: "14.51.36247.0", file: "vc_redist.x86.exe",
        url: "https://download.visualstudio.microsoft.com/download/pr/6ad63323-a427-4c58-8464-9f1f19f62359/F0BAB33A302B3CDB2E11113760D016F54FD3D2632C65BA7834FAC4F0ABD7F1A3/VC_redist.x86.exe",
        sha256: "f0bab33a302b3cdb2e11113760d016f54fd3d2632c65ba7834fac4f0abd7f1a3", license: "Microsoft Software License Terms (aka.ms/VCRedistLicense)", source: "Microsoft, aka.ms/vc14/vc_redist.x86.exe")
    static let vcRedist64 = Pinned(name: "Microsoft Visual C++ v14 Redistributable (x64)", version: "14.51.36247.0", file: "vc_redist.x64.exe",
        url: "https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe",
        sha256: "843068991daaa1f73ad9f6239bce4d0f6a07a51f18c37ea2a867e9beca71295c", license: "Microsoft Software License Terms (aka.ms/VCRedistLicense)", source: "Microsoft, aka.ms/vc14/vc_redist.x64.exe")
    static let directX = Pinned(name: "DirectX End-User Runtime (June 2010)", version: "9.29.1974", file: "directx_Jun2010_redist.exe",
        url: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
        sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b", license: "Microsoft DirectX End-User Runtime terms (shown by the installer)", source: "Microsoft Download Center, id 8109")

    // Sikarugir builds, kept until upstream replacements pass the test suite (decision of 2026-10-23). The engine is pinned by its tarball's
    // SHA-256. The template archive also contains Apple's D3DMetal, so it is never pinned or kept whole: its d3dmetal and apple_gptk folders
    // are skipped while extracting, and only the parts Cosmopolitan uses are pinned, by tree hash.
    static let sikarugirEngine = Pinned(name: "Wine engine (Sikarugir build)", version: "WS12WineSikarugir10.0_8", file: "WS12WineSikarugir10.0_8.tar.xz",
        url: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_8.tar.xz",
        sha256: "2a6bcf2a3bf13cddf825599b6bc1e3659cbf71e1282c6d77141a92f6ac8d4c68", license: "LGPL-2.1-or-later (Wine)", source: "github.com/Sikarugir-App/Engines release v1.0")
    // Cosmos, our Wine 11 engine (the Beta's only engine): the cosmos-engine release tarball, pinned by SHA-256. It unpacks to
    // engine/ plus wswine.bundle -> engine, the layout the engines folder expects.
    static let cosmosEngine = Pinned(name: "Cosmos engine (Wine 11)", version: "cosmos-11.0-r10", file: "cosmos-11.0-r10.tar.gz",
        url: "https://github.com/cyber-prinzesse/cosmos-engine/releases/download/cosmos-11.0-r10/cosmos-11.0-r10.tar.gz",
        sha256: "84a1a05e09c5d6cbffb4f64d079f74949003e63b116a3b4b64f4868967bef0fa", license: "LGPL-2.1-or-later (Wine)", source: "github.com/cyber-prinzesse/cosmos-engine release cosmos-11.0-r10")
    static let sikarugirTemplate = "Template-1.0.24"
    static let sikarugirTemplateURL = "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.24.tar.xz"
    static let templateTrees: [String: String] = [
        "SharedSupport/renderer/dxmt": "dc2158758a80b4256db6dd7a36bc6cd263442dec3c460829b8fe6e0bda159469",
        "SharedSupport/renderer/dxvk": "4f9bfaa4a162a4c4913c53d1e5fc97e7711687e572a7757b6fd255d820353e27",
        "SharedSupport/renderer/dxvk3": "c5803dcdc37e85a3729e528ab408ab54fedbfa78759a0ce40771674d8cceec2a",
        "SharedSupport/renderer/d9vk": "6c60009d88e3e1b92c1173026b484ec57c327659a039676543e3d736a2e3a290",
        "SharedSupport/renderer/cnc_ddraw": "c054c05a28dd5a4bad4603ce12c1f988003393faa110f7d0141e7758a065bebf",
        "Frameworks/GStreamer.framework": "33d20e3dbca70e3890b9e2bccf7e4386b12b5b1a72085519604390f73967dda8",
        "Frameworks/*.dylib": "d7568ebb416e510696a7fc0f5f89a86402ceb6dc851ad4dfeb897e5d9b128d10",
    ]
    static func templateTree(_ app: String, _ part: String) -> String? {
        part == "Frameworks/*.dylib" ? treeHash(app + "/Contents/Frameworks", include: { !$0.contains("/") && $0.hasSuffix(".dylib") })
                                     : treeHash(app + "/Contents/" + part)
    }
    // The pinned template folder, only if every pinned part matches.
    static func verifiedTemplate() -> String? {
        let app = NSHomeDirectory() + "/Library/Application Support/Sikarugir/Template/\(sikarugirTemplate).app"
        return templateTrees.allSatisfy({ templateTree(app, $0.key) == $0.value }) ? app : nil
    }
}

// Tree hash of a folder: SHA-256 over sorted lines "relative/path <sha256>" for regular files and "relative/path -> <target>" for symlinks.
// `include` filters relative paths (nil = everything). Used to pin folders that come out of an archive we can't pin as a whole.
func treeHash(_ dir: String, include: ((String) -> Bool)? = nil) -> String? {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: dir) else { return nil }
    var lines: [String] = []
    for case let rel as String in en where include?(rel) ?? true {
        let p = dir + "/" + rel
        if let t = try? fm.destinationOfSymbolicLink(atPath: p) { lines.append("\(rel) -> \(t)"); continue }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue, let h = sha256File(p) else { continue }
        lines.append("\(rel) \(h)")
    }
    let text = lines.sorted().map { $0 + "\n" }.joined()
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func sha256File(_ path: String) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// The pinned file from support/cache, downloading it when missing or damaged. Returns a path only when the SHA-256 matches. A failed
// or mismatching download is deleted and nothing is installed; a verified file already in the cache is kept.
func fetchPinned(_ p: Pinned, log: (String) -> Void = { _ in }) -> String? {
    let fm = FileManager.default, dir = support + "/cache", path = dir + "/" + p.file, part = path + ".part"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if sha256File(path) == p.sha256 { return path }
    // Test build only: fetch from another URL (a local file:// with wrong bytes) to prove the checksum check.
    let url = isTestBuild ? (ProcessInfo.processInfo.environment["COSMO_TEST_URL_" + p.file.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)] ?? p.url) : p.url
    try? fm.removeItem(atPath: part)
    log("Downloading \(p.name) \(p.version) from \(URL(string: url)?.host ?? "a local file")…\n")
    _ = shell("curl -sfL --retry 2 -m 1800 -o '\(part)' '\(url)'")
    guard let got = sha256File(part) else { log("✗ \(p.name): download failed; nothing installed.\n"); return nil }
    guard got == p.sha256 else {
        try? fm.removeItem(atPath: part)
        log("✗ \(p.name): checksum mismatch (got \(got.prefix(12))…, expected \(p.sha256.prefix(12))…); nothing installed.\n"); return nil
    }
    try? fm.removeItem(atPath: path)
    guard (try? fm.moveItem(atPath: part, toPath: path)) != nil else { return nil }
    log("✓ \(p.name) \(p.version) verified (SHA-256 \(p.sha256.prefix(12))…).\n")
    return path
}

// Wine for helper runs inside a bottle: no driver slots (so nothing is ever copied into system32), msync like every launch.
func plainWine(_ prefix: String) -> String { "env WINEPREFIX='\(prefix)' WINEMSYNC=1 WINEDEBUG=-all '\(wineBin)'" }
