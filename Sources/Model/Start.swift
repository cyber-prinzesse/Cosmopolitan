import SwiftUI

extension Model {
    func start(_ need: Needs, _ cmd: String, _ args: [String], exe: String, block: Bool = false, restartSteam: Bool = false, runner: (@MainActor () -> Void)? = nil) {
        // runner: something other than `wine <cmd>` does the actual start (Legendary for Epic games); everything around it stays the same.
        // Item 24: Steam is never restarted, or stopped for winetricks, while it downloads or a game runs, unless the user says so.
        if restartSteam || (!need.verbs.isEmpty && steamRunning()), let busy = Model.steamBusy(selected) {
            let q = restartSteam ? "Restart Steam to start \(appName(exe))?" : "Stop Steam while \(need.verbs.joined(separator: " ")) installs for \(appName(exe))?"
            guard ask(q, "Steam is \(busy). A download resumes afterwards; a game started from Steam would close.", yes: restartSteam ? "Restart Steam" : "Stop Steam") else {
                log += "\(appName(exe)) not started: Steam is \(busy).\n"; return
            }
        }
        var go = runner ?? { self.wine(self.selected, [cmd] + args + need.args, block: block, env: need.env, drivers: need.drivers, exe: exe) }
        offerReportAfterSession(exe)
        focusAutomation(exe); pauseInBackground(exe, anticheat: need.anticheat != nil); trackPlaytime(exe); scanUntrusted(exe); forceKeyboardLayout(exe); replay(exe)
        cloudSync(exe, phase: "pull"); if options(exe)["CLOUD_SAVES"] == "1" { whenExits(exe) { self.cloudSync(exe, phase: "push") } }
        shaderSync(exe, phase: "pull"); whenExits(exe) { self.shaderSync(exe, phase: "push") }
        if steamGames[exe] != nil || exe.lowercased().hasSuffix("/steam/steam.exe"), !steamRunning() { tuneSteam() }   // Steam is down: safe to edit its config
        // Steam games inherit the env of the *running* Steam, so a per-launch driver change needs Steam restarted with it.
        if restartSteam {
            log += "Restarting Steam so the game gets its drivers…\n"
            let run = go
            go = { Task { @MainActor in await self.stopSteam(); self.tuneSteam(); run() } }
        }
        if !need.runtimes.isEmpty {   // pinned Microsoft runtimes this program needs: install them into the bottle first
            let pfx = "\(bottlesDir)/\(selected)", run = go, rts = need.runtimes
            go = { self.settingUp.insert(exe); Task.detached { for r in rts { Model.installRuntime(r, prefix: pfx) { s in Task { @MainActor in self.log += s } } }; await MainActor.run { self.settingUp.remove(exe); run() } } }
        }
        if need.needsDotNet {   // .NET program in a bottle where .NET isn't verified: probe, install Wine Mono if needed, then start
            let pfx = "\(bottlesDir)/\(selected)", run = go
            go = { self.settingUp.insert(exe); Task.detached { _ = Model.ensureDotNet(pfx) { s in Task { @MainActor in self.log += s } }; await MainActor.run { self.settingUp.remove(exe); self.readiness[exe] = self.launchNeeds(exe); run() } } }
        }
        if need.verbs.isEmpty { go() } else {
            snapshot("before installing \(need.verbs.joined(separator: " "))")
            // Runtime missing: let winetricks fetch it into this bottle first (output streams to the log), then start the program.
            var env = launchEnv(selected); env["WINE"] = wineBin; env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            // winetricks ends many verbs with `wineserver -w`, which waits for EVERY Wine process in the bottle: with Steam running it
            // waits forever. So Steam is stopped first and brought back once the verbs are in (the program starts in between).
            let steamWasUp = steamRunning()
            let run = { self.settingUp.insert(exe); self.exec(winetricks!, ["-q"] + need.verbs, env: env) { self.settingUp.remove(exe); go(); if steamWasUp { self.autostart() } } }
            if steamWasUp { log += "Stopping Steam while winetricks installs \(need.verbs.joined(separator: " ")) (it waits for all Wine processes); Steam comes back afterwards.\n"; Task { @MainActor in await self.stopSteam(); run() } }
            else { run() }
        }
    }

    // Launch check: what the exe imports decides the driver set and any runtime to fetch. Nothing is written to the bottle settings.
}
