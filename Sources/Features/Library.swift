import SwiftUI
import Network

// Item 39: what the Library needs. One shared Model for the window and Settings; whether the Mac is online; each game's status in plain
// words (never bottle, prefix, driver, DLL, registry, Wine, DirectX, Vulkan or msync); "Fix this game"; "Report a problem"; Play for a
// game in any bottle; "Add game" with one bottle per store, created automatically.
extension Model {
    // How long "Starting <game>…" stays in the Library's activity line (test build: COSMO_TEST_STARTING_SECONDS).
    static var startingLabelSeconds: Double { isTestBuild ? Double(ProcessInfo.processInfo.environment["COSMO_TEST_STARTING_SECONDS"] ?? "") ?? 12 : 12 }
    static let shared = Model()

    func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] p in Task { @MainActor in self?.online = p.status == .satisfied } }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    enum GameFix { case repair, appleToolkit, graphics, helperTool }
    // Ready / Setting up… / Needs a fix / Won't run: reason, from the launch check: red (won't start as is) is "Needs a fix" when there is
    // a fix and "Won't run" when there isn't; yellow (automatic work on the first start) and green are "Ready". Offline, the word says
    // whether the game starts without internet.
    func gameState(_ p: String) -> (word: String, reason: String, fix: GameFix?) {
        if settingUp.contains(p) { return ("Setting up…", "Installing what this game needs before its first start.", nil) }
        guard let r = readiness[p] else { return ("Setting up…", "Checking what this game needs.", nil) }
        let n = r.note
        if r.status == .red {
            if let ac = r.anticheat, ac.0 == .red { return ("Won't run: its anti-cheat blocks Macs", "This game's anti-cheat doesn't allow Macs. Cloud gaming (GeForce NOW, Xbox Cloud Gaming) can play it.", nil) }
            if n.contains("unreadable executable") { return ("Won't run: the game file is damaged", "The game's program file is damaged or incomplete. Reinstall or verify it in its store.", nil) }
            if n.contains("missing DLLs") { return ("Won't run: parts of the game are missing", "Files this game needs aren't on this Mac. Reinstall or verify it in its store.", nil) }
            if n.contains("accept Apple's license") || n.contains("Direct3D 12 driver not installed") {
                return ("Needs a fix", "This game needs Apple's Game Porting Toolkit: you download it from Apple and accept Apple's licence.", .appleToolkit)
            }
            if n.contains("driver not installed") { return ("Needs a fix", "A graphics component this game needs is missing. Fix puts it back.", .graphics) }
            if n.contains("brew install") { return ("Needs a fix", "A helper tool this game needs isn't installed (Settings › Show advanced options).", .helperTool) }
            return ("Needs a fix", "Something this game needs isn't set up yet. Fix checks and repairs it.", .repair)
        }
        if !online {
            if r.anticheat != nil { return ("Needs internet", "This game checks online every time it starts.", nil) }
            if steamGames[p] != nil { return ("Works offline in Steam's offline mode", "Start Steam once while online, then choose Steam › Go Offline.", nil) }
            return ("Works offline", "This game doesn't need internet.", nil)
        }
        return ("Ready", r.status == .yellow ? "Sets itself up the first time you play." : "Ready to play.", nil)
    }

    // Library › Refresh: rescan every bottle, fetch missing covers, re-check each game. Spins for at least 0.8 s so a fast scan still reads.
    func refreshLibrary() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            let t0 = Date()
            await Task.yield()
            scan(); fetchArt(); verifyAll()
            let left = 0.8 - Date().timeIntervalSince(t0)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
            refreshing = false
        }
    }
    // Play: a game in another bottle selects that bottle first (every launch path works on the selected one).
    func play(_ p: String) {
        let b = bottleOf(p); if b != selected { selected = b; scan() }
        freeMemoryBeforePlay()
        let starting = "Starting \(appName(p))…"; activity = starting; launch(p)
        // A game starts without making the app busy, so the busy→idle reset never fired and the line stayed for the whole session.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Model.startingLabelSeconds * 1_000_000_000))
            if activity == starting { activity = "" }
        }
    }
    // "Fix this game": a snapshot, Troubleshoot and Repair of its bottle (Repair takes the snapshot), then the game is checked again. A
    // missing graphics component comes back from the pinned template; Apple's toolkit is the user's own step, so its sheet opens.
    func fixGame(_ p: String) {
        let b = bottleOf(p); if b != selected { selected = b; scan() }
        fixHealth(bottle: b)   // item 35: this bottle's health problems first
        switch gameState(p).fix {
        case .appleToolkit?: askD3DMetal = true
        case .graphics?: restoreMissingDrivers(); readiness[p] = launchNeeds(p)
        default:
            activity = "Fixing \(appName(p))…"
            troubleshoot(); repair(); readiness[p] = launchNeeds(p)
            activity = gameState(p).word == "Ready" ? "\(appName(p)) is ready." : "\(appName(p)): \(gameState(p).reason)"
        }
    }
    // "Report a problem": a prefilled bug report for this game opens on our GitHub (full report on the clipboard); nothing is sent.
    func reportProblem(_ p: String) {
        reportBugOnGitHub(for: p)
        activity = "A prefilled bug report is open on GitHub and the full report is on the clipboard. Nothing is sent until you press Submit."
    }
    // "Add game" › a store: open it where it is installed; otherwise it gets its own bottle (named after the store), created automatically.
    func addStore(_ s: Store) {
        for b in bottles where FileManager.default.fileExists(atPath: "\(bottlesDir)/\(b)/drive_c") {
            if let exe = s.exes.map({ "\(bottlesDir)/\(b)/drive_c/\($0)" }).first(where: { FileManager.default.fileExists(atPath: $0) }) { play(exe); return }
        }
        let name = s.rawValue.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ".", with: "")
        activity = "Getting \(s.rawValue) ready…"
        if bottles.contains(name) { selected = name; scan(); installStore(s) }
        else { createBottle(name) { self.refresh(); self.selected = name; self.scan(); self.installStore(s) } }
    }
}
