import SwiftUI

extension Model {
    func optionsPath(_ exe: String) -> String { "\(bottlesDir)/\(bottleOf(exe))/options/\((exe as NSString).lastPathComponent).env" }
    func options(_ exe: String) -> [String: String] {
        var o: [String: String] = [:]
        for l in ((try? String(contentsOfFile: optionsPath(exe), encoding: .utf8)) ?? "").components(separatedBy: "\n") where !l.hasPrefix("#") {
            let kv = l.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { o[kv[0]] = kv[1] }
        }
        return o
    }
    func saveOptions(_ exe: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (optionsPath(exe) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: optionsPath(exe), atomically: true, encoding: .utf8)
        readiness[exe] = launchNeeds(exe)
        if steamGames[exe] != nil { syncSteamLaunchOptions(for: exe) }   // keep Steam's LaunchOptions in step when ARGS (etc.) change
    }
    static let optionsTemplate = """
    # One setting per line. Lines starting with # are ignored.
    # ARGS=-dx11 -windowed          extra command-line arguments
    # DRIVERS=dxmt,d9vk             driver set for this program (overrides Auto)
    # CEF_GPU=1                     keep Chromium's GPU path (default off for programs that embed libcef.dll — otherwise the window stays black under Wine)
    # LANG=ja_JP.UTF-8              run in another locale; ja/zh/ko also install matching fonts
    # MOUSE_CAPTURE=1               keep the cursor inside the game window (camera-heavy games)
    # US_KEYBOARD=1                 switch to a QWERTY Latin layout you already have enabled while this game runs (default; 0 = never)
    # DUALSENSE=native              give this game the real DualSense (adaptive triggers, haptics, touchpad) instead of an Xbox-style pad;
    #                               only for games with PC DualSense support — others then lose XInput. Steam restarts when the mode flips.
    # FOCUS_SHORTCUT=Gaming         run this macOS Shortcut when the game starts and when it exits
    # PAUSE_IN_BACKGROUND=1         suspend the game while another app is in front (single-player only)
    # ROSETTA_ADVERTISE_AVX=0       force AVX off/on for this program (auto-detected otherwise)
    # D3DM_MAX_FPS=60               frame-rate cap (D3DMetal); DXMT_CONFIG=d3d11.preferredMaxFrameRate=60 for DXMT
    # FULL_SPEED=1                  no cooler profile for this game (on battery, Low Power Mode, MacBook Air): no 60 fps cap, full resolution
    # CLOUD_SAVES=1                 mirror this program's save folders to iCloud Drive (non-Steam programs; Steam has Steam Cloud)
    # REPLAY=1                      rolling 30 s screen recording while playing: ⌃⌥⌘R saves the last clip, ⌃⌥⌘S a screenshot
    # WINEDLLOVERRIDES=xaudio2_7=n  any other KEY=VALUE becomes an environment variable

    """
}
