import SwiftUI
import Carbon

// §9.7 Instant replay and clips, opt-in per game (Options REPLAY=1). While the game runs, the system recorder (screencapture -v) writes
// rolling 30-second segments of the main display, keeping only the last two. ⌃⌥⌘R saves those two segments (≈30–60 s of the past) to
// ~/Movies/Cosmopolitan Clips/<game>/; ⌃⌥⌘S saves a screenshot there. Cost: one continuous screen recording (a few % CPU, disk churn in
// the temp folder); nothing runs when REPLAY is off. Hotkeys use Carbon's RegisterEventHotKey, which needs no accessibility permission.
final class ReplayRecorder {
    static let shared = ReplayRecorder()
    var game = "", running = false, segment = 0, hotkeys: [EventHotKeyRef?] = []
    var dir: String { NSTemporaryDirectory() + "cosmo-replay" }
    var gallery: String { NSHomeDirectory() + "/Movies/\(appDataName) Clips/\(game)" }
    func start(game: String, log: @escaping (String) -> Void) {
        self.game = game; running = true
        _ = shell("rm -rf '\(dir)'; mkdir -p '\(dir)' '\(gallery)'")
        installHotkeys(log: log)
        Thread.detachNewThread { [self] in   // one 30 s recording after another; keep the last two files
            while running {
                segment += 1
                _ = shell("screencapture -v -V 30 -x '\(dir)/seg\(segment).mov' 2>/dev/null")
                _ = shell("ls -t '\(dir)'/seg*.mov 2>/dev/null | tail -n +3 | xargs -I{} rm -f {}")
            }
        }
        log("Replay: rolling 30 s recording on; ⌃⌥⌘R saves the last ~30–60 s, ⌃⌥⌘S a screenshot → \(gallery)\n")
    }
    func stop() { running = false; _ = shell("pkill -INT -f 'screencapture -v' 2>/dev/null"); hotkeys.forEach { if let h = $0 { UnregisterEventHotKey(h) } }; hotkeys = [] }
    func saveClip() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        _ = shell("pkill -INT -f 'screencapture -v' 2>/dev/null; sleep 1; n=0; for f in $(ls -t '\(dir)'/seg*.mov 2>/dev/null | head -2); do n=$((n+1)); cp \"$f\" '\(gallery)/\(stamp)-part$n.mov'; done")
        return "Replay saved: \(gallery)/\(stamp)-part*.mov\n"
    }
    func screenshot() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        _ = shell("screencapture -x '\(gallery)/\(stamp).png'"); return "Screenshot saved: \(gallery)/\(stamp).png\n"
    }
    private func installHotkeys(log: @escaping (String) -> Void) {
        guard hotkeys.isEmpty else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID(); GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let msg = id.id == 1 ? ReplayRecorder.shared.saveClip() : ReplayRecorder.shared.screenshot()
            Task { @MainActor in ReplayRecorder.shared.onMessage?(msg) }
            return noErr
        }, 1, &spec, nil, nil)
        onMessage = log
        let mods = UInt32(controlKey | optionKey | cmdKey)
        var h1: EventHotKeyRef?, h2: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_R), mods, EventHotKeyID(signature: 0x434F534D, id: 1), GetApplicationEventTarget(), 0, &h1)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), mods, EventHotKeyID(signature: 0x434F534D, id: 2), GetApplicationEventTarget(), 0, &h2)
        hotkeys = [h1, h2]
    }
    var onMessage: ((String) -> Void)?
}

extension Model {
    func replay(_ exe: String) {
        guard options(exe)["REPLAY"] == "1" else { return }
        ReplayRecorder.shared.start(game: appName(exe).replacingOccurrences(of: "/", with: "-")) { [weak self] m in self?.log += m }
        whenExits(exe) { ReplayRecorder.shared.stop(); self.log += "Replay: recording stopped (game exited).\n" }
    }
}
