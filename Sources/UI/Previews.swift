import SwiftUI

// Step 4 of the redesign brief: previews of each state, decoupled from Model so they render in Xcode without a running app. A sample card
// mirrors gameTile's layout (cover placeholder, name, StatusTag, Play) for Ready / Won't run / Starting / long name; plus the empty
// library, a 30-card grid, the status tags, and the button/control gallery. Visual reference only — the live Library uses the Model.
#if DEBUG
private struct SampleCard: View {
    let name: String, kind: GameStatusKind, status: String, reason: String?
    init(_ name: String, _ kind: GameStatusKind, _ status: String, reason: String? = nil) { self.name = name; self.kind = kind; self.status = status; self.reason = reason }
    var body: some View {
        VStack(alignment: .leading, spacing: Cosmo.Space.m) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: "gamecontroller").font(.system(size: 34)).foregroundStyle(Cosmo.textTertiary))
                .background(Cosmo.surface).clipShape(RoundedRectangle(cornerRadius: Cosmo.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Cosmo.Radius.card).strokeBorder(Cosmo.hairline, lineWidth: 1))
            VStack(alignment: .leading, spacing: Cosmo.Space.s) {
                Text(name).font(Cosmo.title).foregroundStyle(Cosmo.textPrimary).lineLimit(1)
                if kind == .wontRun {
                    VStack(alignment: .leading, spacing: Cosmo.Space.xs) {
                        StatusTag(kind: .wontRun, text: "Won't run")
                        Text(reason ?? "").font(Cosmo.caption).foregroundStyle(Cosmo.textSecondary).lineLimit(2, reservesSpace: true)
                    }
                } else { StatusTag(kind: kind, text: status).frame(height: 32, alignment: .topLeading) }
                HStack(spacing: Cosmo.Space.s) {
                    Button("Play") {}.buttonStyle(OutlineButtonStyle()).fixedSize().disabled(kind == .wontRun)
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis").foregroundStyle(Cosmo.textSecondary).frame(width: 28, height: 28)
                }
            }
        }.padding(Cosmo.Space.m).cardSurface().frame(width: 180)
    }
}

#Preview("Card states") {
    HStack(alignment: .top, spacing: Cosmo.Space.l) {
        SampleCard("Ready Game", .ready, "Ready")
        SampleCard("Won't Run", .wontRun, "Won't run", reason: "This game's anti-cheat doesn't allow Macs.")
        SampleCard("Starting", .starting, "Setting up…")
        SampleCard("A very long game name that truncates", .ready, "Ready")
    }.padding(Cosmo.Space.xl).background(Cosmo.background)
}

#Preview("Status tags") {
    VStack(alignment: .leading, spacing: Cosmo.Space.l) {
        StatusTag(kind: .ready, text: "Ready")
        StatusTag(kind: .wontRun, text: "Won't run")
        StatusTag(kind: .starting, text: "Starting…")
        StatusTag(kind: .setting, text: "Needs a fix")
        StatusTag(kind: .offline, text: "Works offline")
    }.padding(Cosmo.Space.xl).background(Cosmo.background)
}

#Preview("Controls") {
    VStack(alignment: .leading, spacing: Cosmo.Space.l) {
        HStack(spacing: Cosmo.Space.m) {
            Button("Add game") {}.buttonStyle(FilledButtonStyle())
            Button("Play") {}.buttonStyle(OutlineButtonStyle())
            Button("Disabled") {}.buttonStyle(OutlineButtonStyle()).disabled(true)
            CircularGlassButton(systemImage: "gearshape", label: "Settings") {}
            CircularGlassButton(systemImage: "slider.horizontal.3", label: "Tools") {}
        }
        Text("Library").font(Cosmo.display(64)).tracking(Cosmo.displayTracking).foregroundStyle(Cosmo.textPrimary)
        Text("6 games · 4 ready").font(Cosmo.caption).foregroundStyle(Cosmo.textSecondary)
    }.padding(Cosmo.Space.xl).frame(width: 760).background(Cosmo.background)
}

#Preview("Empty library") {
    VStack(spacing: Cosmo.Space.l) {
        Text("No games yet").font(Cosmo.display(40)).tracking(-0.045 * 40).foregroundStyle(Cosmo.textPrimary)
        Text("Get your games from Steam, GOG, Epic or Battle.net, or install one from a file.").font(Cosmo.body).foregroundStyle(Cosmo.textSecondary)
        Button("Add your first game") {}.buttonStyle(FilledButtonStyle())
    }.frame(width: 760, height: 480).background(Cosmo.background)
}

#Preview("30 games") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 162, maximum: 200), spacing: Cosmo.Space.l)], spacing: Cosmo.Space.l) {
            ForEach(0..<30, id: \.self) { i in SampleCard("Game \(i + 1)", i % 5 == 0 ? .wontRun : .ready, "Ready", reason: "A reason.").frame(maxWidth: .infinity) }
        }.padding(Cosmo.Space.xl)
    }.frame(width: 820, height: 600).background(Cosmo.background)
}
#endif
