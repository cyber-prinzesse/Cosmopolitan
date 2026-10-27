import SwiftUI

// Stores. Battle.net is a Windows client: its official installer is downloaded into the bottle and run like any installer (same launch
// checks, snapshot, log), and its games show up in the grid through the normal scan. Epic and GOG go through native open-source
// clients instead of their Windows launchers: Legendary (Epic) and lgogdownloader (GOG) sign in, list the library and download games
// into the bottle; Cosmopolitan launches them with the engine, drivers and options it uses for everything else.
// (GOG Galaxy 2.1 was tried first: its Qt 6 UI needs a render backend and fails the Direct3D 11 probe under every layer available here,
// D3DMetal, DXMT, DXVK and Wine's own, so its windows never get drawn. GOG games are DRM-free, so nothing is lost without it.)
var epicGames: [String: (id: String, name: String)] = [:]      // exe path -> Legendary app name / title (installed games)
var epicOwned: [(id: String, name: String)] = []                 // signed-in Epic library (refreshed in the background by scan)
var gogOwned: [(id: String, name: String)] = []                  // signed-in GOG library: gamename slug / title

enum Store: String, CaseIterable, Identifiable {
    case steam = "Steam", battlenet = "Battle.net", epic = "Epic Games Launcher"
    var id: String { rawValue }
    var url: String {
        switch self {
        case .steam: return "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
        case .battlenet: return "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe"
        case .epic: return "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi"
        }
    }
    var file: String { self == .steam ? "SteamSetup.exe" : self == .battlenet ? "Battle.net-Setup.exe" : "EpicGamesLauncherInstaller.msi" }
    var exes: [String] {
        switch self {
        case .steam: return ["Program Files (x86)/Steam/steam.exe"]
        case .battlenet: return ["Program Files (x86)/Battle.net/Battle.net Launcher.exe", "Program Files (x86)/Battle.net/Battle.net.exe"]
        case .epic: return ["Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe", "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"]
        }
    }
    var args: [String] { self == .epic ? ["-SkipBuildPatchPrereq"] : [] }   // the launcher otherwise insists on installing redistributables it cannot under Wine
}

extension Model {
    // Store clients get a fixed driver set regardless of the bottle's Direct3D 12 marker: GOG Galaxy's Qt 6 UI passes its Direct3D 11
    // probe on DXMT but not on D3DMetal (then it falls back to software drawing and parts of the UI stay blank).
    func storeDrivers(_ exe: String) -> [String]? {
        let n = (exe as NSString).lastPathComponent.lowercased()
        if n.hasPrefix("galaxyclient") || n.hasPrefix("epicgameslauncher") { return ["dxmt", "d9vk", "cnc_ddraw"].filter { installedDrivers().contains($0) } }
        return nil
    }
    func storeExe(_ s: Store, in bottle: String? = nil) -> String? { s.exes.map { "\(bottlesDir)/\(bottle ?? selected)/drive_c/\($0)" }.first { FileManager.default.fileExists(atPath: $0) } }

    // Epic's launcher self-updates on every start: it stages the new build under ProgramData\Epic\EpicGamesLauncher\Data\Update\Install,
    // reports success, but under Wine the final move into Program Files never happens, so it restarts forever ("Requiring 1223 files"
    // each time). Finishing the move ourselves before each launch, and giving it the installed manifest it looks for, ends the loop.
    func finishEpicLauncherUpdate(_ exe: String) {
        let c = "\(bottlesDir)/\(selected)/drive_c", data = "\(c)/ProgramData/Epic/EpicGamesLauncher/Data", fm = FileManager.default
        let dst = ((exe as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent   // …/Launcher/Portal/Binaries
        let launcher = ((dst as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent   // …/Launcher
        var moved = 0
        for top in ["Engine", "Portal"] {
            let src = "\(data)/Update/Install/\(top)"
            guard let en = fm.enumerator(atPath: src) else { continue }
            for case let rel as String in en {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: "\(src)/\(rel)", isDirectory: &isDir) else { continue }
                let to = "\(launcher)/\(top)/\(rel)"
                if isDir.boolValue { try? fm.createDirectory(atPath: to, withIntermediateDirectories: true); continue }
                try? fm.removeItem(atPath: to)
                if (try? fm.copyItem(atPath: "\(src)/\(rel)", toPath: to)) != nil { moved += 1 }
            }
        }
        let installed = "\(data)/Launcher.manifest", update = "\(data)/LauncherUpdate.manifest"
        if !fm.fileExists(atPath: installed), fm.fileExists(atPath: update) { try? fm.copyItem(atPath: update, toPath: installed) }
        else if moved > 0, fm.fileExists(atPath: update) { try? fm.removeItem(atPath: installed); try? fm.copyItem(atPath: update, toPath: installed) }
        if moved > 0 { log += "Epic Games Launcher: finished its pending update (\(moved) files moved into place).\n" }
        // Epic Online Services: the launcher refuses to install games without it and its own "Restart and Install" goes through the
        // updater service, which is the loop above. The installer ships with the update (Portal/Extras/EOS); run it silently once.
        let eosDir = "\(c)/Program Files (x86)/Epic Games/Epic Online Services", eosSetup = "\(launcher)/Portal/Extras/EOS/EpicOnlineServicesInstaller.exe"
        if !fm.fileExists(atPath: eosDir), fm.fileExists(atPath: eosSetup) {
            log += "Installing Epic Online Services (needed before the launcher installs games)…\n"
            // /productid is mandatory; 42c61cfd… is the launcher's own EOS product id (what it logs as ProductId at boot).
            _ = sh("env \(launchEnv(selected).map { "\($0.key)='\($0.value)'" }.joined(separator: " ")) '\(wineBin)' '\(winPath(eosSetup))' /install /quiet productid=42c61cfdc3d24af5a8333b3284d47240 >/dev/null 2>&1")   // no slash before productid, or it is "missing"
        }
    }

    // Download the official installer into <bottle>/drive_c/installers (restricted bottles have no Z:, so installers must live on C:)
    // and run it. Battle.net also gets Arial (its UI shows boxes without it) and its client config set to software rendering before
    // the first start, which is the known fix for a black launcher under Wine.
    func installStore(_ s: Store) {
        guard !selected.isEmpty else { log += "Create or select a bottle first.\n"; return }
        let dir = "\(bottlesDir)/\(selected)/drive_c/installers"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dst = "\(dir)/\(s.file)"
        busy = true; log += "Downloading the \(s.rawValue) installer…\n"
        Task.detached {
            let r = shell("curl -fsSL --retry 3 -o '\(dst)' '\(s.url)' 2>&1 && echo __ok")
            await MainActor.run {
                self.busy = false
                guard r.contains("__ok") else { self.log += "Download failed: \(r)\n"; return }
                if s == .battlenet { self.battlenetConfig() }
                if s == .steam { self.steamBottleTweaks() }
                if dst.hasSuffix(".msi") {   // Epic: silent MSI install, nothing to click; the client appears in the grid when msiexec is done
                    self.log += "\(s.rawValue): installing…\n"
                    self.wine(self.selected, ["msiexec", "/i", self.winPath(dst), "/qn"]) { self.scan() }
                    return
                }
                self.log += "\(s.rawValue): follow the installer; the client appears in the grid when it is done.\n"
                var need = self.prepare(dst)
                if s == .battlenet, winetricks != nil, !need.verbs.contains("arial") { need.verbs.append("arial") }
                self.start(need, self.winPath(dst), [], exe: dst, block: true)
            }
        }
    }

    // Steam under Wine: its web helper must stay on Wine's own Direct3D (DXMT's dxgi crashes it), Steam Input must not grab the pad
    // (its XInput hooks don't work under Wine, so XInput is disabled for steam.exe only), and 96 DPI keeps its window a normal size.
    func steamBottleTweaks() {
        func reg(_ k: String, _ n: String, _ t: String, _ v: String) {   // recorded in the registry ledger as bottle settings (never pruned)
            let exe = k.components(separatedBy: "AppDefaults\\").dropFirst().first?.components(separatedBy: "\\").first ?? ""
            Model.regSet(selected, k, n, v, type: t, exe: exe, owner: "bottle")
        }
        for d in ["d3d11", "dxgi", "d3d10core"] { reg("HKCU\\Software\\Wine\\AppDefaults\\steamwebhelper.exe\\DllOverrides", d, "REG_SZ", "builtin") }
        for d in ["xinput1_1", "xinput1_2", "xinput1_3", "xinput1_4", "xinput9_1_0", "xinputuap", "dinput", "dinput8"] { reg("HKCU\\Software\\Wine\\AppDefaults\\steam.exe\\DllOverrides", d, "REG_SZ", "") }
        for d in ["gameoverlayrenderer", "gameoverlayrenderer64"] { reg("HKCU\\Software\\Wine\\DllOverrides", d, "REG_SZ", "") }
        reg("HKCU\\Control Panel\\Desktop", "LogPixels", "REG_DWORD", "96")
        log += "Steam: bottle prepared (web helper on Wine's Direct3D, Steam Input kept off the controller, 96 DPI).\n"
    }
    // Battle.net.config: hardware acceleration and streaming off (CEF under Wine renders black otherwise). Merged, never clobbered.
    func battlenetConfig() {
        let p = "\(bottlesDir)/\(selected)/drive_c/users/\(NSUserName())/AppData/Roaming/Battle.net/Battle.net.config"
        var cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p)))) as? [String: Any] ?? [:]
        var client = cfg["Client"] as? [String: Any] ?? [:]
        var streaming = client["Streaming"] as? [String: Any] ?? [:]
        streaming["StreamingEnabled"] = "false"; client["Streaming"] = streaming; client["HardwareAcceleration"] = "false"; cfg["Client"] = client
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: p)) }
    }

    // Extra places the plain scan does not look: GOG game folders (one level deeper) and Legendary's installed Epic games.
    // Also refreshes the owned-library lists for the Install menus in the background (network calls, off the main thread).
    func storeGames(_ bottle: String? = nil) -> [String] {
        let c = "\(bottlesDir)/\(bottle ?? selected)/drive_c", fm = FileManager.default
        var out: [String] = []
        for root in ["GOG Games", "Program Files (x86)/GOG Galaxy/Games", "Program Files (x86)/GOG Games"] {
            for game in (try? fm.contentsOfDirectory(atPath: "\(c)/\(root)")) ?? [] where !game.hasPrefix(".") {
                for f in (try? fm.contentsOfDirectory(atPath: "\(c)/\(root)/\(game)")) ?? [] where f.lowercased().hasSuffix(".exe") && !skipExes.contains(where: { f.lowercased().contains($0) }) && !f.lowercased().hasPrefix("unins") {
                    out.append("\(c)/\(root)/\(game)/\(f)")
                }
            }
        }
        for s in Store.allCases { if let e = storeExe(s, in: bottle) { out.append(e) } }   // store clients that live deeper than the plain scan looks (Epic's Portal/Binaries/Win64)
        epicGames = [:]
        // Legendary is a Python program (~0.4 s per call): never run it inside a scan. Use the last answer and refresh it in the
        // background; when the installed list changed, scan once more.
        if let l = legendary {
            let cacheFile = "\(bottlesDir)/\(selected)/options/.epic-installed.json"
            Task { @MainActor in   // the slow part runs detached; the rescan happens back on the main actor
                let changed = await Task.detached { () -> Bool in
                    let fresh = shell("'\(l)' list-installed --json 2>/dev/null")
                    let old = (try? String(contentsOfFile: cacheFile, encoding: .utf8)) ?? ""
                    guard !fresh.isEmpty, fresh != old else { return false }
                    try? fresh.write(toFile: cacheFile, atomically: true, encoding: .utf8); return true
                }.value
                if changed { self.scan() }
            }
        }
        if legendary != nil, let data = try? Data(contentsOf: URL(fileURLWithPath: "\(bottlesDir)/\(selected)/options/.epic-installed.json")),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let l = legendary {
            for g in list {
                guard let path = g["install_path"] as? String, path.hasPrefix(c), let exe = g["executable"] as? String, let id = g["app_name"] as? String else { continue }
                let p = "\(path)/\(exe.replacingOccurrences(of: "\\", with: "/"))"
                if fm.fileExists(atPath: p) { epicGames[p] = (id, g["title"] as? String ?? id); out.append(p) }
            }
            // `list --json` came back empty for this account while the plain listing (with -T for third-party-managed titles) had the
            // games, so the text form is parsed:  " * Title (App name: xyz | Version: …)"; "  + …" lines are DLC and are skipped.
            if epicSignedIn(), epicOwned.isEmpty { Task.detached {   // once per app run (a network call), not on every scan
                let s = shell("'\(l)' list --platform Windows -T 2>/dev/null")   // on macOS Legendary defaults to the Mac platform, which lists nothing here
                var owned: [(id: String, name: String)] = []
                for line in s.components(separatedBy: "\n") where line.hasPrefix(" * ") {
                    guard let r = line.range(of: " (App name: ") else { continue }
                    let title = String(line.dropFirst(3)[..<r.lowerBound]), rest = line[r.upperBound...]
                    let id = String(rest.prefix { $0 != " " && $0 != "|" && $0 != ")" })
                    if !id.isEmpty { owned.append((id, title)) }
                }
                epicOwned = owned.sorted { $0.1 < $1.1 }
            } }
        }
        if let g = lgog, gogSignedIn(), gogOwned.isEmpty { Task.detached {
            let s = shell("'\(g)' --list json --platform w 2>/dev/null")
            guard let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) else { return }
            let arr = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["games"] as? [[String: Any]]) ?? []
            gogOwned = arr.compactMap { g in (g["gamename"] as? String).map { ($0, g["title"] as? String ?? $0) } }.sorted { $0.1 < $1.1 }
        } }
        return out
    }

    // ---- Epic (Legendary) ----
    // Legendary is not in Homebrew; pipx puts it in ~/.local/bin.
    var legendary: String? { ["/opt/homebrew/bin/legendary", NSHomeDirectory() + "/.local/bin/legendary", "/usr/local/bin/legendary"].first { FileManager.default.fileExists(atPath: $0) } }
    func epicSignedIn() -> Bool { legendary != nil && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/legendary/user.json") }
    func installLegendary() {
        exec("/bin/sh", ["-c", "command -v pipx >/dev/null || brew install pipx; pipx install legendary-gl"], env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) {
            self.log += self.legendary == nil ? "Legendary did not install; see the log above.\n" : "Legendary installed. Stores… › Sign in to Epic Games.\n"
        }
    }
    // Epic's login with the redirect to the code endpoint (Legendary's client id). The in-app web view uses a private session, so this is
    // always a fresh login, which is the only place Epic shows pending policy acceptances (a signed-in browser otherwise lands on
    // "corrective_action_required" instead of the authorizationCode).
    static let epicLoginURL = URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!
    func epicSignIn(code: String) {
        guard let l = legendary else { return }
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        exec(l, ["auth", "--code", c]) { self.scan(); if self.epicSignedIn() { self.log += "Signed in to Epic Games. Stores… › Install Epic game.\n" } }
    }
    func epicSignOut() { guard let l = legendary else { return }; epicOwned = []; exec(l, ["auth", "--delete"]) { self.scan() } }
    // Downloads into <bottle>/drive_c/Games/Epic/<Game>; progress streams to the log; the tile appears when the download is done.
    func installEpic(_ app: String) {
        guard let l = legendary else { return }
        snapshot("before installing Epic game \(app)")
        exec(l, ["install", app, "--platform", "Windows", "--base-path", "\(bottlesDir)/\(selected)/drive_c/Games/Epic", "-y"], block: false) { self.scan() }
    }
    // Legendary only describes the launch (`launch --json`: exe, Epic's auth arguments, env); Cosmopolitan starts Wine itself, as for every
    // other program. Letting Legendary spawn Wine does not work: it exits right after spawning, its pipes close, and the game dies on
    // its first write to stderr.
    func launchEpic(_ app: String, exe: String) {
        guard let l = legendary else { return }
        var need = prepare(exe)
        let js = shell("'\(l)' launch '\(app)' --json --wine '\(wineBin)' --wine-prefix '\(bottlesDir)/\(selected)' 2>/dev/null")
        guard let d = js.data(using: .utf8), let info = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            log += "Legendary could not prepare the launch (not signed in, or the game needs an update: Stores… › Sign in / reinstall).\n"; return
        }
        for k in ["game_parameters", "egl_parameters", "user_parameters"] { need.args += (info[k] as? [String]) ?? [] }
        for (k, v) in (info["environment"] as? [String: String]) ?? [:] where k != "CX_BOTTLE" && k != "WINEPREFIX" { need.env[k] = v }
        start(need, winPath(exe), extraArgs(exe), exe: exe)
    }

    // ---- GOG (lgogdownloader) ----
    // lgogdownloader keeps the sign-in in ~/.config/lgogdownloader (it honours XDG_CONFIG_HOME): galaxy_tokens.json (OAuth access and
    // refresh token) and cookies.txt, both mode 600. It has no Keychain support. The test build can use a stand-in (COSMO_TEST_LGOG).
    var lgog: String? { Model.lgogPath }
    nonisolated static var lgogPath: String? {
        let t = isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_LGOG"] : nil
        return (t.map { [$0] } ?? ["/opt/homebrew/bin/lgogdownloader", "/usr/local/bin/lgogdownloader"]).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    nonisolated static func gogTokens() -> Bool { ((try? FileManager.default.attributesOfItem(atPath: NSHomeDirectory() + "/.config/lgogdownloader/galaxy_tokens.json"))?[.size] as? Int ?? 0) > 20 }
    func gogSignedIn() -> Bool { lgog != nil && Model.gogTokens() }
    // GOG's native Mac client. Its package installs a privileged helper the client refuses to start without (an unpacked copy in
    // ~/Applications says "Essential components … are missing"), so the package runs through macOS's own administrator prompt.
    func installNativeGalaxy() {
        let script = """
        set -e; brew fetch --cask gog-galaxy >/dev/null; P=$(ls -t ~/Library/Caches/Homebrew/downloads/*galaxy_client*.pkg | head -1)
        osascript -e "do shell script \\"/usr/sbin/installer -pkg '$P' -target /\\" with administrator privileges"
        echo "GOG Galaxy (Mac) installed"; open "/Applications/GOG Galaxy.app"
        """
        log += "GOG Galaxy (Mac): macOS will ask for your password; the client needs a system helper that only the installer can add.\n"
        exec("/bin/sh", ["-c", script], env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
    }
    func installLgog() { exec("/bin/sh", ["-c", "brew install lgogdownloader"], env: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { self.log += self.lgog == nil ? "lgogdownloader did not install; see the log above.\n" : "lgogdownloader installed. Stores… › Sign in to GOG.\n" } }
    // GOG's own login page (what lgogdownloader --browser-login prints); after login the browser lands on embed.gog.com/on_login_success?…code=…
    // The test build can start from another page (COSMO_TEST_GOG_LOGIN_URL), e.g. one that redirects straight to a success address.
    static var gogLoginURL: URL {
        if isTestBuild, let s = ProcessInfo.processInfo.environment["COSMO_TEST_GOG_LOGIN_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=default&brand=gog")!
    }
    // The address GOG's login lands on carries the code: https://embed.gog.com/on_login_success?origin=client&code=…
    nonisolated static func isGogRedirect(_ u: URL) -> Bool {
        u.scheme == "https" && (u.host == "gog.com" || u.host?.hasSuffix(".gog.com") == true) && u.path.contains("on_login_success")
            && URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "code" && !($0.value ?? "").isEmpty } == true
    }
    // Item 22: lgogdownloader trades the code in that address for tokens. Returns "Signed in to GOG." or why not, in lgogdownloader's own
    // words; never hangs (60 s, or COSMO_TEST_GOG_TIMEOUT in the test build).
    nonisolated static func gogSignIn(redirectURL: String) -> (ok: Bool, message: String) {
        guard let g = lgogPath else { return (false, "Sign-in failed: lgogdownloader isn't installed (Stores… › Set up GOG).") }
        let s = redirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), isGogRedirect(u) else { return (false, "Sign-in failed: that isn't the address GOG's login ends on (https://embed.gog.com/on_login_success?…code=…).") }
        let limit = isTestBuild ? Double(ProcessInfo.processInfo.environment["COSMO_TEST_GOG_TIMEOUT"] ?? "") ?? 60 : 60
        let p = Process(); p.executableURL = URL(fileURLWithPath: g); p.arguments = ["--browser-login"]
        let inp = Pipe(), out = Pipe(); p.standardInput = inp; p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (false, "Sign-in failed: lgogdownloader could not start (\(error.localizedDescription)).") }
        inp.fileHandleForWriting.write(Data((s + "\n").utf8)); try? inp.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) { if p.isRunning { p.terminate() } }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        if p.terminationReason == .uncaughtSignal { return (false, "Sign-in failed: GOG didn't answer within \(Int(limit)) seconds. Check the internet connection and try again.") }
        if p.terminationStatus == 0, gogTokens() { return (true, "Signed in to GOG.") }
        let why = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains("://") }.suffix(2).joined(separator: " ")
        return (false, "Sign-in failed: " + (why.isEmpty ? "lgogdownloader stopped with code \(p.terminationStatus) and no message." : why))
    }
    func gogSignIn(redirectURL: String, done: @escaping @MainActor (Bool, String) -> Void = { _, _ in }) {
        Task.detached { let r = Model.gogSignIn(redirectURL: redirectURL)
            await MainActor.run { self.log += r.message + "\n"; logToFile(r.message + "\n"); if r.ok { gogOwned = []; self.scan() }; done(r.ok, r.message) } }
    }
    func gogSignOut() { gogOwned = []; for f in ["galaxy_tokens.json", "cookies.txt"] { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.config/lgogdownloader/" + f) }; scan() }
    func gogInstalled() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: "\(bottlesDir)/\(selected)/drive_c/GOG Games")) ?? []) }
    // Installs the Windows build straight from GOG's content system into C:\GOG Games\<gamename> (DRM-free, no installer to click through).
    func installGog(_ gamename: String) {
        guard let g = lgog else { return }
        snapshot("before installing GOG game \(gamename)")
        let dir = "\(bottlesDir)/\(selected)/drive_c/GOG Games"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        exec(g, ["--galaxy-install", gamename, "--galaxy-platform", "w", "--directory", dir, "--no-color", "--no-unicode", "--no-window-progress"], block: false) { self.scan() }
    }
}
