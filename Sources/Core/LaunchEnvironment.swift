import SwiftUI

// A bottle's drivers/<name> is a link to the installed backend folder, so each bottle can later point at its own backend version.
func bottleDriverDir(_ bottle: String, _ d: String) -> String {
    let dir = "\(bottlesDir)/\(bottle)/drivers", link = dir + "/" + d, fm = FileManager.default
    guard fm.fileExists(atPath: "\(bottlesDir)/\(bottle)") else { return "\(driversDir)/\(d)" }
    if (try? fm.destinationOfSymbolicLink(atPath: link)) != "\(driversDir)/\(d)" {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true); try? fm.removeItem(atPath: link)
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: "\(driversDir)/\(d)")
    }
    return link
}
// Environment a bottle's programs are launched with (also used by Dock shortcuts).
func launchEnv(_ bottle: String, drivers: [String]? = nil, fullSpeed: Bool = false) -> [String: String] {   // drivers: per-launch override of the bottle's DRIVERS
    // Every Wine run in a bottle (launches and reg/winecfg helpers alike) builds this environment first, so a stale prefix is updated
    // here, without driver slots; otherwise Wine's own automatic update runs inside the first command and copies the drivers in.
    updatePrefixIfStale("\(bottlesDir)/\(bottle)")
    // VK_DRIVER_FILES: registers MoltenVK with the Vulkan loader; without it DXVK has no GPU (res=-9).
    var e = ["WINEPREFIX": "\(bottlesDir)/\(bottle)", "WINEDEBUG": "-all",
             "VK_DRIVER_FILES": engineDir + "/MoltenVK_icd.json",
             "MVK_CONFIG_RESUME_LOST_DEVICE": "1", "MVK_CONFIG_FAST_MATH_ENABLED": "1",
             "MVK_CONFIG_LOG_LEVEL": "1",   // errors only: MoltenVK otherwise prints its 150-line extension list for every VkInstance (Qt apps make six at startup)
             // Video/audio decoding (Media Foundation, DirectShow) goes through GStreamer; the framework comes from the Sikarugir template.
             "GST_PLUGIN_PATH": support + "/engines/gstreamer/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
             "GST_PLUGIN_SYSTEM_PATH_1_0": support + "/engines/gstreamer/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
             // DualSense through SDL's own hidapi driver: rumble reaches the pad's motors via XInput vibration; player LED off (no distraction).
             "SDL_JOYSTICK_HIDAPI": "1", "SDL_JOYSTICK_HIDAPI_PS5": "1", "SDL_JOYSTICK_HIDAPI_PS5_PLAYER_LED": "0",
             // Wine hands DOS programs to `dosbox` from PATH; apps launched from Finder don't see Homebrew's bin otherwise.
             "PATH": "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
    let t = (try? String(contentsOfFile: "\(bottlesDir)/\(bottle)/cosmopolitan.env", encoding: .utf8)) ?? ""
    for l in t.components(separatedBy: "\n") {
        let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { e[kv[0]] = kv[1] }
    }
    // msync: thread waits on Mach semaphores instead of server round-trips — less CPU, no effect on rendering. (The DLSS→MetalFX bridge stays OFF:
    // it was the real cause of the Dawnwalker lag; FSR in the game menu is the right upscaler under D3DMetal.)
    if e["WINEMSYNC"] == nil { e["WINEMSYNC"] = "1" }
    // Rosetta emulates x87 floating-point slowly, so 32-bit programs whose DLLs use x87 (old D3D9 games, the i386 C runtime) crawl on a
    // Wine 11 engine. r29-type Wine 11 engines carry athei's x87sidecar hook (Highball patch 0012): with ROSETTA_X87_PATH set, every
    // 32-bit program re-execs through the sidecar's ARM64 x87 JIT (measured ~10x on a cos loop). Engine-gated — Wine 10 has no such hook —
    // and only when the MIT-licensed sidecar binary is installed. The patch only re-execs i386 targets, so it's a no-op for 64-bit.
    let x87 = (isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_X87SIDECAR"] : nil) ?? x87sidecarPath
    if engineIsWine11(), FileManager.default.fileExists(atPath: x87) { e["ROSETTA_X87_PATH"] = x87 }
    // On battery, in Low Power Mode or thermally throttled (§7.8, item 32): 60 fps cap in D3DMetal and DXMT, DXMT renders at 2/3 and MetalFX-upscales.
    // Off again when plugged in, Low Power Mode off and cool; always on for a fanless Mac (Power.swift).
    // D3DM_MAX_FPS only where the installed D3DMetal documents it (4.0 beta); 3.0 ignores it, and the launch check says the cap isn't available.
    // FULL_SPEED=1 in a game's options (`fullSpeed`) or the bottle's: never this profile there (a light game that stays cool anyway).
    if e["D3DM_MAX_FPS"] == nil, !fullSpeed, e["FULL_SPEED"] != "1", batteryCapWanted() {
        if d3dmetalFrameCap() { e["D3DM_MAX_FPS"] = "60" }
        e["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=60;d3d11.metalSpatialUpscaleFactor=1.5"
    }
    // Upstream DXVK can't run on Metal; the Sikarugir DXVK builds here can.
    // Only the engine's per-slot variables, never plain WINEDLLPATH: tried 2026-10-22, it made DXMT's dxgi/d3d11 the builtin for every
    // process including steamwebhelper (which must stay on Wine's own D3D) → "Steamwebhelper is not responding".
    // Engines without Sikarugir's slots (Highball's Wine 11, GPTK-style) take the same folders as one WINEDLLPATH_PREPEND list.
    let prepend = engineUsesPrepend(); var front: [String] = []; var useD3DMetal = false
    for d in drivers ?? driverList(e, bottle: bottle) {
        guard let s = driverSlot[d], driverUsable(d) else { continue }   // a driver that can't create a device here would only crash the game
        let dir = bottleDriverDir(bottle, d) + "/wine"   // loaded per launch from the bottle's own drivers/ folder; never copied into system32
        if prepend { front.append(dir) } else { e["WINEDLLPATH_" + s] = dir }
        // libd3dshared dlopen()s this value as-is; the dylibs are reached through the symlinked x86_64-unix path, so @rpath can't find the framework on its own.
        if d == "d3dmetal" { e["D3DMETAL_FRAMEWORK_PATH"] = "\(driversDir)/d3dmetal/external/D3DMetal.framework/D3DMetal"; useD3DMetal = true }
        // vkd3d-proton runs on KosmicKrisp only (this process's Vulkan is KosmicKrisp then, not MoltenVK). Its default feature level is 11_1
        // there (no sparse residency); 12_1 is what Direct3D 12 games ask for, and GravityMark renders correctly with it.
        if d == "vkd3d", let icd = kosmicKrispICD() { e["VK_DRIVER_FILES"] = icd; if e["VKD3D_FEATURE_LEVEL"] == nil { e["VKD3D_FEATURE_LEVEL"] = "12_1" } }
    }
    if !front.isEmpty { e["WINEDLLPATH_PREPEND"] = front.joined(separator: ":") }
    // The engine's win32u (hack 24905): when CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal, KMTQAITYPE_WDDM_2_7_CAPS reports HwSchEnabled /
    // HwSchSupported / HwSchEnabledByDefault so DX12 games see GPU scheduling (mapc-engine WineRunner sets this for the same reason).
    // Dropped if the user's bottle/options already set the variable. (vulkan.c only special-cases the value "wined3d" with CX_LIBVULKAN.)
    if useD3DMetal, e["CX_ACTIVE_GRAPHICS_BACKEND"] == nil { e["CX_ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal" }
    return e
}

// The active engine's driver hook: Sikarugir's per-slot WINEDLLPATH_<slot>, or one WINEDLLPATH_PREPEND list (from its ntdll, once per engine).
nonisolated(unsafe) private var prependEngines: [String: Bool] = [:]
private let prependLock = NSLock()
func engineUsesPrepend() -> Bool {
    let ntdll = engineDir + "/lib/wine/x86_64-unix/ntdll.so"
    prependLock.lock(); defer { prependLock.unlock() }
    if let v = prependEngines[ntdll] { return v }
    let d = FileManager.default.contents(atPath: ntdll) ?? Data()
    let v = d.range(of: Data("WINEDLLPATH_DXMT".utf8)) == nil && d.range(of: Data("WINEDLLPATH_PREPEND".utf8)) != nil
    prependEngines[ntdll] = v; return v
}
// Wine 11's layout: the real loader (with the address-space reserve) sits in lib/wine/x86_64-unix and bin/wine hands over to it.
func engineIsWine11() -> Bool { engineIsWine11(engineName) }
// For a named engine folder under support/engines (the Settings picker labels and the switch warning), not only the active one.
func engineIsWine11(_ name: String) -> Bool { FileManager.default.fileExists(atPath: support + "/engines/\(name)/wswine.bundle/lib/wine/x86_64-unix/wine") }
