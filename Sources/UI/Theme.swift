import SwiftUI

// Transition shim (redesign brief: one source of truth = Cosmo). The old green-frost names now resolve to the monochrome CosmoTheme, so
// every screen keeps building while each is migrated onto Cosmo/CosmoTheme directly. No styling lives here; this file is deleted once the
// last screen is migrated. Color(hex:) and the components live in CosmoTheme.swift.
enum Theme {
    static let accent = Cosmo.textPrimary   // no accent colour in the new look — the old "accent" is off-white
    static let surface = Cosmo.surface
    static let frost = 1.0
}

extension View {
    func frost() -> some View { cosmoWindow() }
    func glassCard(_ radius: CGFloat = 2, veil: Double = 1) -> some View { cardSurface() }
    func primaryButton() -> some View { buttonStyle(FilledButtonStyle()) }
    func secondaryButton() -> some View { buttonStyle(OutlineButtonStyle()) }
}

// Icon rows (What's new, checks): a monochrome secondary-grey icon, not an accent colour.
struct AccentIcon: LabelStyle {
    func makeBody(configuration c: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) { c.icon.foregroundStyle(Cosmo.textSecondary).frame(width: 22); c.title }
    }
}
