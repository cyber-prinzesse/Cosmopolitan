import SwiftUI

// Item 39, redesigned (monochrome brief, 24 Oct): the main window. Every bottle's games, split into Launchers and Games. Each has Play,
// its status in words without relying on colour (StatusTag), and a ··· menu. Grid or list (club-program) view. Only visual — every action,
// label and flow is unchanged. Add game is the one filled high-contrast control; Tools and Settings are the circular glass buttons.
extension ContentView {
    @ViewBuilder var libraryView: some View {
        VStack(alignment: .leading, spacing: Cosmo.Space.xl) {
            header
            ForEach(activeNotices.indices, id: \.self) { activeNotices[$0] }
            if m.library.isEmpty { emptyLibrary }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Cosmo.Space.xxl) {
                        let launchers = m.library.filter(isLauncher), games = m.library.filter { !isLauncher($0) }
                        if !launchers.isEmpty { librarySection("Launchers", launchers) }
                        if !games.isEmpty { librarySection("Games", games) }
                    }.padding(.vertical, Cosmo.Space.xs)
                }
            }
            if m.busy || m.setupRunning || !m.activity.isEmpty { activityBar }
        }
        .padding(.horizontal, Cosmo.Space.xxl).padding(.bottom, Cosmo.Space.xl).padding(.top, Cosmo.Space.l)
        .onChange(of: m.busy) { _, b in if !b, m.activity.hasSuffix("…") { m.activity = "" } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Cosmo.Space.l) {
            VStack(alignment: .leading, spacing: Cosmo.Space.xs) {
                Text("Library").font(Cosmo.display(64)).tracking(Cosmo.displayTracking).foregroundStyle(Cosmo.textPrimary)
                Text(librarySummary).font(Cosmo.caption).foregroundStyle(Cosmo.textSecondary).tabularDigits()
            }
            Spacer(minLength: 0)
            HStack(spacing: Cosmo.Space.m) {
                layoutToggle
                addGameMenu
                if showAdvancedOption { CircularGlassButton(systemImage: "slider.horizontal.3", label: "Tools") { advancedMode = true } }
                CircularGlassButton(systemImage: "gearshape", label: "Settings") { openSettings() }
            }.padding(.top, Cosmo.Space.xl).padding(.trailing, Cosmo.Space.s)   // off the top-right edge
        }
    }

    // Grid / List, as two square buttons; the active one is filled off-white.
    private var layoutToggle: some View {
        HStack(spacing: 0) {
            ForEach([("square.grid.2x2", false), ("list.bullet", true)], id: \.0) { icon, list in
                Button { libraryList = list } label: {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(libraryList == list ? Cosmo.background : Cosmo.textSecondary)
                        .frame(width: 32, height: 28)
                        .background(libraryList == list ? Cosmo.textPrimary : .clear)
                }.buttonStyle(.plain)
                .accessibilityLabel(list ? "List view" : "Grid view")
            }
        }.overlay(RoundedRectangle(cornerRadius: Cosmo.Radius.button).strokeBorder(Cosmo.hairline, lineWidth: 1))
    }

    var librarySummary: String {
        let n = m.library.count, ready = m.library.filter { ["Ready", "Works offline"].contains(m.gameState($0).word) }.count
        return n == 0 ? "Windows games on your Mac" : "\(n) game\(n == 1 ? "" : "s") · \(ready) ready"
    }

    func isLauncher(_ p: String) -> Bool { Store.allCases.contains { s in s.exes.contains { p.hasSuffix($0) } } }

    @ViewBuilder func librarySection(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Cosmo.Space.m) {
            Text(title).font(Cosmo.caption).foregroundStyle(Cosmo.textSecondary)
            if libraryList {
                VStack(spacing: 0) {
                    ForEach(items, id: \.self) { p in gameRow(p); if p != items.last { Rectangle().fill(Cosmo.hairline).frame(height: 1) } }
                }.cardSurface()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 162, maximum: 200), spacing: Cosmo.Space.l)], alignment: .leading, spacing: Cosmo.Space.l) {
                    ForEach(items, id: \.self) { gameTile($0) }
                }
            }
        }
    }

    // MARK: - Grid card

    func gameTile(_ p: String) -> some View {
        let s = m.gameState(p), red = s.word.hasPrefix("Won't run")
        return VStack(alignment: .leading, spacing: Cosmo.Space.m) {
            cover(p)
            VStack(alignment: .leading, spacing: Cosmo.Space.s) {
                Text(appName(p)).font(Cosmo.title).foregroundStyle(Cosmo.textPrimary).lineLimit(1)
                statusLine(p, s).frame(height: 54, alignment: .topLeading)   // uniform status height so cards in a row are even
                HStack(spacing: Cosmo.Space.s) {
                    Button { m.play(p) } label: { Text("Play") }.buttonStyle(OutlineButtonStyle()).fixedSize().disabled(m.busy || red)
                    if s.word == "Needs a fix" { Button("Fix") { m.fixGame(p) }.buttonStyle(OutlineButtonStyle()).fixedSize().disabled(m.busy) }
                    Spacer(minLength: 0)
                    tileMenu(p)
                }
            }
        }.padding(Cosmo.Space.m).cardSurface()
    }

    // MARK: - List row (club program)

    func gameRow(_ p: String) -> some View {
        let s = m.gameState(p), red = s.word.hasPrefix("Won't run")
        return HStack(spacing: Cosmo.Space.l) {
            cover(p).frame(width: 56, height: 56).fixedSize()
            VStack(alignment: .leading, spacing: Cosmo.Space.xs) {
                Text(appName(p)).font(Cosmo.title).foregroundStyle(Cosmo.textPrimary).lineLimit(1)
                statusLine(p, s)
            }
            Spacer(minLength: Cosmo.Space.l)
            if s.word == "Needs a fix" { Button("Fix") { m.fixGame(p) }.buttonStyle(OutlineButtonStyle()).fixedSize().disabled(m.busy) }
            Button { m.play(p) } label: { Text("Play") }.buttonStyle(OutlineButtonStyle()).fixedSize().disabled(m.busy || red)
            tileMenu(p)
        }.padding(.horizontal, Cosmo.Space.l).padding(.vertical, Cosmo.Space.m)
    }

    // Status in words, never colour alone (StatusTag): Ready = square, Won't run = inverted label + reason, else a square + the word.
    @ViewBuilder func statusLine(_ p: String, _ s: (word: String, reason: String, fix: Model.GameFix?)) -> some View {
        let kind: GameStatusKind = s.word.hasPrefix("Won't run") ? .wontRun : (s.word == "Ready" || s.word == "Works offline") ? .ready : s.word == "Setting up…" ? .starting : .setting
        Button { reasonFor = p } label: {
            if kind == .wontRun {
                VStack(alignment: .leading, spacing: Cosmo.Space.xs) {
                    StatusTag(kind: .wontRun, text: "Won't run")
                    Text(s.reason).font(Cosmo.caption).foregroundStyle(Cosmo.textSecondary).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                }
            } else {
                StatusTag(kind: kind, text: s.word).frame(height: 32, alignment: .topLeading)
            }
        }.buttonStyle(.plain).help(s.reason)
        .popover(isPresented: Binding(get: { reasonFor == p }, set: { if !$0 { reasonFor = nil } })) {
            VStack(alignment: .leading, spacing: Cosmo.Space.m) {
                Text(s.word).font(Cosmo.title).foregroundStyle(Cosmo.textPrimary)
                Text(s.reason).font(Cosmo.body).foregroundStyle(Cosmo.textSecondary).fixedSize(horizontal: false, vertical: true)
                if s.fix != nil { Button("Fix") { reasonFor = nil; m.fixGame(p) }.buttonStyle(FilledButtonStyle()) }
            }.padding(Cosmo.Space.l).frame(width: 300).background(Cosmo.raised)
        }
    }

    func tileMenu(_ p: String) -> some View {
        Menu {
            Button("Fix this game") { m.fixGame(p) }
            Button("Report a problem") { m.reportProblem(p) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            Divider()
            Button("Uninstall…") { uninstallExe = p }
        } label: { Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).foregroundStyle(Cosmo.textSecondary).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions for \(appName(p))")
    }

    // Full-bleed cover on a #0D0D0D tile, square corners. Launcher logos shown unmodified; game icons centred on the surface, no glow.
    func cover(_ p: String) -> some View {
        let art = m.artPath(p).flatMap { NSImage(contentsOfFile: $0) }, img = Image(nsImage: art ?? m.icons[p] ?? NSWorkspace.shared.icon(for: .applicationBundle))
        return Color.clear.aspectRatio(isLauncher(p) ? 1 : 3 / 4, contentMode: .fit)   // one aspect per section: launchers square, games 3:4
            .overlay {
                if art != nil { img.resizable().interpolation(.high).scaledToFill() }
                else { img.resizable().interpolation(.high).scaledToFit().padding(Cosmo.Space.l) }
            }
            .background(Cosmo.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cosmo.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Cosmo.Radius.card).strokeBorder(Cosmo.hairline, lineWidth: 1))
            .id(m.artVersion)
    }

    // MARK: - Add game, notices, empty, activity

    var addGameMenu: some View { addGameMenu(title: "Add game") }
    func addGameMenu(title: String) -> some View {
        Menu {
            Button("Steam") { m.addStore(.steam) }
            if m.lgog == nil { Button("GOG") { m.installLgog(); loginStore = "gog" } }
            else if !m.gogSignedIn() { Button("GOG") { loginStore = "gog" } }
            else { Menu("GOG") { let mine = m.gogInstalled(); ForEach(gogOwned.filter { !mine.contains($0.id) }, id: \.id) { g in Button(g.name) { m.installGog(g.id) } } } }
            if m.legendary == nil { Button("Epic Games") { m.installLegendary() } }
            else if !m.epicSignedIn() { Button("Epic Games") { loginStore = "epic" } }
            else { Menu("Epic Games") { let mine = Set(epicGames.values.map { $0.id }); ForEach(epicOwned.filter { !mine.contains($0.id) }, id: \.id) { g in Button(g.name) { m.installEpic(g.id) } } } }
            Button("Battle.net") { m.addStore(.battlenet) }
            Divider()
            Button("I have an installer file…") { pick() }
        } label: { Label(title, systemImage: "plus") }.menuStyle(.button).buttonStyle(FilledButtonStyle()).fixedSize().disabled(m.busy)
    }

    // Notices as black rectangles with a hairline border; no colour-coded circles.
    var activeNotices: [AnyView] {
        var out: [AnyView] = []
        if let p = m.pendingSteamRestart {
            out.append(AnyView(notice("Steam restarts once it's free (it is \(p.busy) right now), so \(p.why).") {
                Button("Restart now") { m.pendingSteamRestart = nil; m.restartSteam(p.bottle, because: p.why) }.buttonStyle(OutlineButtonStyle())
                Button("Not now") { m.pendingSteamRestart = nil }.buttonStyle(OutlineButtonStyle())
            }))
        }
        if let pr = m.problem {
            out.append(AnyView(notice(pr.text + " Fix checks and repairs it; a snapshot is taken first.") {
                Button("Fix") { m.problem = nil; m.fixGame(pr.game) }.buttonStyle(FilledButtonStyle())
                Button("Dismiss") { m.problem = nil }.buttonStyle(OutlineButtonStyle())
            }))
        }
        if !m.healthProblems.isEmpty {
            out.append(AnyView(notice("Cosmopolitan found something to fix: " + m.healthProblems.map(\.text).joined(separator: " ")) {
                Button("Fix") { m.fixHealth() }.buttonStyle(FilledButtonStyle())
            }))
        }
        if !m.online { out.append(AnyView(notice("You're offline. Each game says whether it starts without internet.") { EmptyView() })) }
        if hintStep < 3 && !m.library.isEmpty {
            out.append(AnyView(notice(["Press Play to start a game. The first start can take a moment while it sets itself up.",
                                       "Add game gets games from Steam, GOG, Epic or Battle.net, or installs one from a file.",
                                       "The ··· menu on a game can fix it, report a problem or show its files."][hintStep]) {
                Button(hintStep < 2 ? "Next" : "Got it") { hintStep += 1 }.buttonStyle(OutlineButtonStyle())
            }))
        }
        return out
    }

    func notice<B: View>(_ text: String, @ViewBuilder _ buttons: () -> B) -> some View {
        HStack(spacing: Cosmo.Space.l) {
            Rectangle().fill(Cosmo.textPrimary).frame(width: 3).frame(maxHeight: .infinity)
            Text(text).font(Cosmo.body).foregroundStyle(Cosmo.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Cosmo.Space.l)
            buttons()
        }.padding(Cosmo.Space.l).frame(maxWidth: .infinity, alignment: .leading).cardSurface(Cosmo.raised).fixedSize(horizontal: false, vertical: true)
    }

    var emptyLibrary: some View {
        VStack(spacing: Cosmo.Space.l) {
            Spacer()
            Text("No games yet").font(Cosmo.display(40)).tracking(-0.045 * 40).foregroundStyle(Cosmo.textPrimary)
            Text("Get your games from Steam, GOG, Epic or Battle.net, or install one from a file.").font(Cosmo.body).foregroundStyle(Cosmo.textSecondary).multilineTextAlignment(.center)
            addGameMenu(title: "Add your first game").padding(.top, Cosmo.Space.s)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var activityBar: some View {
        HStack(spacing: Cosmo.Space.m) {
            if m.busy || m.setupRunning { ProgressView(value: m.setupRunning ? m.setupProgress : nil).frame(width: 140).tint(Cosmo.textPrimary) }
            Text(m.setupRunning ? "Getting things ready…" : m.activity.isEmpty ? "Working on it…" : m.activity).font(Cosmo.caption).foregroundStyle(Cosmo.textSecondary).lineLimit(1)
        }.padding(.horizontal, Cosmo.Space.l).padding(.vertical, Cosmo.Space.m).cardSurface(Cosmo.raised)
    }
}
