import SwiftUI

extension Model {
    // Run something when a program's process is gone (polled; Steam games are started by Steam, so we can't wait on a child).
    func whenExits(_ exe: String, _ then: @escaping @MainActor () -> Void) {
        let name = (exe as NSString).lastPathComponent
        Task { @MainActor in
            let pat = pgrepPattern(name)
            _ = pat
            for _ in 0..<30 { try? await Task.sleep(nanoseconds: 2_000_000_000); if isRunning(name) { break } }   // wait up to 60 s for it to appear
            while isRunning(name) { try? await Task.sleep(nanoseconds: 10_000_000_000) }
            then()
        }
    }
    // §9.8 Focus automation: Options FOCUS_SHORTCUT=<Shortcut name> runs that Shortcut when the game starts and again when it exits (make it a toggle).
    func focusAutomation(_ exe: String) {
        guard let s = options(exe)["FOCUS_SHORTCUT"], !s.isEmpty else { return }
        _ = sh("shortcuts run \(shq("\(s)")) >/dev/null 2>&1 &"); log += "Focus: ran Shortcut “\(s)”; runs again when \(appName(exe)) exits.\n"
        whenExits(exe) { _ = self.sh("shortcuts run \(shq("\(s)")) >/dev/null 2>&1 &"); self.log += "Focus: ran Shortcut “\(s)” (game exited).\n" }
    }
    // §9.9 Pause in background: Options PAUSE_IN_BACKGROUND=1 suspends the game's process while another app is frontmost (SIGSTOP/SIGCONT).
    // Refused for anti-cheat and online-flagged games; the game must be a single-player title you tested this with.
    func pauseInBackground(_ exe: String, anticheat: Bool) {
        guard options(exe)["PAUSE_IN_BACKGROUND"] == "1" else { return }
        guard !anticheat else { log += "Pause in background ignored for \(appName(exe)): anti-cheat present.\n"; return }
        let name = (exe as NSString).lastPathComponent
        let nc = NSWorkspace.shared.notificationCenter
        let o = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pids = procFind(name).map(String.init).joined(separator: " ")
            guard !pids.isEmpty else { return }
            let isGame = app.executableURL?.path.contains("/wswine.bundle/") == true || app.localizedName == appName(exe)
            _ = sh("kill -\(isGame ? "CONT" : "STOP") \(pids) 2>/dev/null")
        }
        pauseObservers.append(o); log += "Pause in background armed for \(appName(exe)).\n"
        whenExits(exe) { NSWorkspace.shared.notificationCenter.removeObserver(o); self.pauseObservers.removeAll { $0 === o } }
    }
}
