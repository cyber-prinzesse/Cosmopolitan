import SwiftUI

// The one source of truth for the look (redesign brief, 24 Oct): Berlin-techno monochrome. Black/gray/white only — game cover art is the
// sole colour. Square corners, 1 px hairlines instead of shadows, Instrument Sans, glass only on floating controls. The circular glass
// buttons (Tools, Settings) are the one round thing in a square interface, with chromatic aberration on hover — the Aberration Ark signature.
enum Cosmo {
    // MARK: Colour (dark only). Status never relies on colour: see StatusTag.
    static let background = Color(hex: 0x000000)
    static let surface    = Color(hex: 0x0D0D0D)   // content cards / launcher tiles
    static let raised     = Color(hex: 0x161616)   // popovers, toasts, raised controls
    static let hairline   = Color(hex: 0x2A2A2A)   // 1 px rules between rows/cards
    static let rule       = Color(hex: 0x5E5E5B)   // heavier rule / disabled / decorative
    static let textPrimary   = Color(hex: 0xEDEDEA)
    static let textSecondary = Color(hex: 0x9A9A96)
    static let textTertiary  = Color(hex: 0x5E5E5B)  // disabled/decorative only

    // MARK: Spacing scale (brief): 4 / 8 / 12 / 16 / 24 / 32 / 48.
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 48 }
    // MARK: Radii — square everything except the circular glass buttons.
    enum Radius { static let card: CGFloat = 2, button: CGFloat = 2, label: CGFloat = 2, toast: CGFloat = 2 }
    // MARK: Motion — hard and fast, ease-out, no springs. Honour Reduce Motion at the call site.
    enum Motion { static let fast = Animation.easeOut(duration: 0.12), normal = Animation.easeOut(duration: 0.16) }

    // MARK: Type — Instrument Sans (bundled, registered via ATSApplicationFontsPath), SF Pro fallback if it failed to load.
    static let hasInstrument = NSFont(name: "InstrumentSans-Regular", size: 12) != nil
    private static func sans(_ ps: String, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        hasInstrument ? .custom(ps, fixedSize: size) : .system(size: size, weight: weight)
    }
    static func display(_ size: CGFloat = 64) -> Font { sans("InstrumentSans-Medium", size, .medium) }  // screen titles, tracking applied at use
    static var title: Font { sans("InstrumentSans-Medium", 22, .medium) }
    static var body: Font { sans("InstrumentSans-Regular", 15, .regular) }
    static var caption: Font { sans("InstrumentSans-Medium", 12, .medium) }
    static let displayTracking: CGFloat = -0.045 * 64   // -0.045em at 64 pt
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

extension View {
    // The whole window: black frost — the desktop blurred through a heavy black veil (translucent depth, no colour). Dark scheme, hidden
    // title bar so content runs to the top edge. Content cards stay solid (brief). Goes near-solid under Reduce Transparency.
    func cosmoWindow() -> some View {
        background {
            ZStack { BlackFrost(); Cosmo.background.opacity(0.66) }.ignoresSafeArea()
        }.tint(Cosmo.textPrimary).preferredColorScheme(.dark)
    }
    // A content card / tile: solid surface, 1 px hairline, square. Never glass, never a shadow (brief).
    func cardSurface(_ fill: Color = Cosmo.surface) -> some View {
        let s = RoundedRectangle(cornerRadius: Cosmo.Radius.card)
        return background(s.fill(fill)).overlay(s.strokeBorder(Cosmo.hairline, lineWidth: 1))
    }
    // Tabular (monospaced) digits for counts and times.
    func tabularDigits() -> some View { monospacedDigit() }
}

// Black frost: a behind-window blur that lets the desktop show through faintly under the black veil. Makes the window see-through and
// hides the title bar. NSVisualEffectView turns opaque by itself under System Settings › Accessibility › Reduce transparency.
private struct BlackFrost: NSViewRepresentable {
    final class V: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.isOpaque = false; w.backgroundColor = .clear; w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden; w.styleMask.insert(.fullSizeContentView)
        }
    }
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = V(); v.material = .underWindowBackground; v.blendingMode = .behindWindow; v.state = .active; v.appearance = NSAppearance(named: .darkAqua); return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Buttons

// The only filled, high-contrast button (Add game): off-white fill, black text, square. Rectangular.
struct FilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var on
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(Cosmo.caption).foregroundStyle(on ? Cosmo.background : Cosmo.textTertiary)
            .padding(.horizontal, Cosmo.Space.m).padding(.vertical, Cosmo.Space.s)
            .background(RoundedRectangle(cornerRadius: Cosmo.Radius.button).fill(on ? Cosmo.textPrimary : Cosmo.surface))
            .overlay(RoundedRectangle(cornerRadius: Cosmo.Radius.button).strokeBorder(on ? .clear : Cosmo.hairline, lineWidth: 1))
            .opacity(c.isPressed ? 0.85 : 1)
    }
}

// Play / secondary actions: 1 px off-white outline that fills off-white (black text) on hover. Disabled: tertiary grey, no fill.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var on
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration c: Configuration) -> some View {
        let active = (hover || c.isPressed) && on
        return c.label.font(Cosmo.caption)
            .foregroundStyle(!on ? Cosmo.textTertiary : active ? Cosmo.background : Cosmo.textPrimary)
            .padding(.horizontal, Cosmo.Space.m).padding(.vertical, Cosmo.Space.s)
            .background(RoundedRectangle(cornerRadius: Cosmo.Radius.button).fill(active ? Cosmo.textPrimary : .clear))
            .overlay(RoundedRectangle(cornerRadius: Cosmo.Radius.button).strokeBorder(on ? Cosmo.textPrimary : Cosmo.textTertiary, lineWidth: 1))
            .animation(reduceMotion ? nil : Cosmo.Motion.fast, value: active)
            .onHover { hover = $0 }
    }
}

// The circular Liquid Glass button (Tools, Settings) — the one round element. Chromatic aberration on hover/focus. Needs a VoiceOver label.
struct CircularGlassButton: View {
    let systemImage: String, label: String, action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Button(action: action) {
            ZStack {
                if hover && !reduceMotion {   // RGB split on hover (never on text) — the Aberration Ark signature
                    glyph(Cosmo.textPrimary).colorMultiply(Color(hex: 0xFF4040)).offset(x: -1.2)
                    glyph(Cosmo.textPrimary).colorMultiply(Color(hex: 0x40FF40))
                    glyph(Cosmo.textPrimary).colorMultiply(Color(hex: 0x4060FF)).offset(x: 1.2)
                }
                glyph(Cosmo.textPrimary).opacity(hover && !reduceMotion ? 0.0 : 1)
            }
            .frame(width: 34, height: 34).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(circleGlass)
        .overlay(Circle().strokeBorder(Cosmo.hairline, lineWidth: 1))
        .animation(reduceMotion ? nil : Cosmo.Motion.fast, value: hover)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
    private func glyph(_ c: Color) -> some View { Image(systemName: systemImage).font(.system(size: 14, weight: .medium)).foregroundStyle(c).blendMode(.plusLighter) }
    @ViewBuilder private var circleGlass: some View {
        if reduceTransparency { Circle().fill(Cosmo.raised) }
        else if #available(macOS 26, *) { Circle().fill(.clear).glassEffect(.regular, in: .circle) }
        else { Circle().fill(.ultraThinMaterial) }
    }
}

// MARK: - Status (never colour alone; brief)

enum GameStatusKind { case ready, wontRun, starting, setting, offline }

struct StatusTag: View {
    let kind: GameStatusKind, text: String
    @State private var blink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: Cosmo.Space.s) {
            switch kind {
            case .wontRun:
                Text(text).font(Cosmo.caption).foregroundStyle(Cosmo.background)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Cosmo.Radius.label).fill(Cosmo.textPrimary))   // inverted label
            default:
                Rectangle().fill(kind == .ready ? Cosmo.textPrimary : Cosmo.textSecondary)
                    .frame(width: 7, height: 7).opacity(kind == .starting && blink && !reduceMotion ? 0.2 : 1)
                Text(text).font(Cosmo.caption).foregroundStyle(kind == .offline ? Cosmo.textTertiary : Cosmo.textSecondary)
            }
        }
        .onAppear { if kind == .starting && !reduceMotion { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { blink = true } } }
    }
}
