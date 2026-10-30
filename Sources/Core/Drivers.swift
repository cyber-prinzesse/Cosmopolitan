import SwiftUI

func driverList(_ env: [String: String], bottle: String) -> [String] {
    let l: [String]
    if let v = env["DRIVERS"], v != "auto" { l = v.split(separator: ",").map(String.init) }
    else { l = FileManager.default.fileExists(atPath: dx12Marker(bottle)) && d3dmetalOK ? autoDriverSetDX12 : autoDriverSet }   // no license → plain DXMT set
    return l.filter { ($0 != "d3dmetal" || d3dmetalOK) && driverUsable($0) }
}
// DXVK 3.x refuses every MoltenVK device ("required feature 'shaderCullDistance'": Metal has no cull distance), so it renders nothing here.
// Measured with tests/stress on DXVK-Sikarugir v3.1.1 (folders d9vk, dxvk3) + MoltenVK 1.4.1: no adapter for D3D9 or D3D11, the game aborts.
// The D3D9 v2.3 in dxvk and Wine's own D3D9 both render. ponytail: decided from the version file; re-run tests/stress when a new DXVK or
// MoltenVK arrives, and drop this if MoltenVK gains cull distance.
func driverUsable(_ d: String) -> Bool {
    if d == "vkd3d" { return kosmicKrispICD() != nil }
    let v = (try? String(contentsOfFile: "\(driversDir)/\(d)/version", encoding: .utf8)) ?? ""
    return v.range(of: #"DXVK[^ ]*-v([3-9]|[1-9][0-9])\."#, options: .regularExpression) == nil
}
// vkd3d (Direct3D 12 fallback when D3DMetal crashes): vkd3d-proton's d3d12/d3d12core plus DXVK's dxgi, on KosmicKrisp (Mesa's Vulkan on
// Metal). MoltenVK lacks what vkd3d-proton needs (geometry shaders, cull distance); KosmicKrisp only ships in engines with Highball's
// layout, which load drivers through WINEDLLPATH_PREPEND (Sikarugir's engine has no slot for it). Measured 2026-10-29 (GravityMark 10k
// asteroids): renders the same image as D3DMetal at about a third of its frame rate, so it is only ever the fallback.
// The engine's KosmicKrisp has no ICD file of its own: one is written next to the drivers, per engine. nil = can't run here.
func kosmicKrispICD() -> String? {
    let lib = engineDir + "/lib/wine/x86_64-unix/libvulkan_kosmickrisp.dylib"
    guard FileManager.default.fileExists(atPath: lib), engineUsesPrepend() else { return nil }
    let icd = "\(driversDir)/vkd3d/KosmicKrisp_icd-\(engineName).json"
    // is_portability_driver must be false: as a portability driver the loader hides it from winevulkan (no VK_KHR_portability_enumeration), res=-9.
    let json = #"{ "file_format_version": "1.0.1", "ICD": { "library_path": "\#(lib.replacingOccurrences(of: "\"", with: "\\\""))", "api_version": "1.3.0", "is_portability_driver": false } }"# + "\n"
    if (try? String(contentsOfFile: icd, encoding: .utf8)) != json {
        guard (try? json.write(toFile: icd, atomically: true, encoding: .utf8)) != nil else { return nil }
    }
    return icd
}
func installedDrivers() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: driversDir)) ?? []).filter { driverSlot[$0] != nil }.sorted()
}
func driverLabel(_ d: String) -> String {
    if d == "d3dmetal", let i = Model.d3dmetalInfo(driversDir + "/d3dmetal") { return "d3dmetal  (\(i.pretty), from \(i.source))" }
    let v = (try? String(contentsOfFile: "\(driversDir)/\(d)/version", encoding: .utf8))?.components(separatedBy: "\n").first ?? ""
    return (v.isEmpty ? d : "\(d)  (\(v))") + (driverUsable(d) ? "" : " — not used: can't run on Metal's Vulkan")
}
let skipExes = ["unins", "oalinst", "vcredist", "physx", "uninst", "crashhandler", "crashpad", "helper", "update", "setup", "redist", "dxsetup", "dotnet", "service", "minidump", "errorreporter", "crash", "report", "overlay", "sysinfo", "streaming", "unitycrashhandler", "easyanticheat", "battleye", "beclient", "pbsvc", "xigncode", "nprotect", "blizzarderror", "gamesessionmonitor", "fmsiscan", "systeminfo"]
