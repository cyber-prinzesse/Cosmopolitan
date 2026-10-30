import AppKit
import SwiftUI

// Native "preparing bottle" stand-in for Wine's old "please wait…" window (off in Cosmos; still under us on Wine 10).
// Black square, glass only, rounded-square outline with a travelling thick segment (~1.6 s / lap). Shown only in the GUI
// after ~0.5 s so quick wineboot runs don't flash. VoiceOver: "Preparing <bottle>".
enum PreparingWindow {
    private static var panel: NSPanel?
    private static var showWork: DispatchWorkItem?
    private static var bottle = ""
    private static var forceShow = false   // --preview-preparing: show even in cliMode

    // Call around a wineboot (or preview). Nested begin/end pairs are not supported — one window at a time.
    static func begin(bottle name: String, force: Bool = false) {
        let show = { force || !cliMode }
        DispatchQueue.main.async {
            guard show() else { return }
            forceShow = force
            bottle = name
            showWork?.cancel()
            let work = DispatchWorkItem { present() }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    static func end() {
        DispatchQueue.main.async {
            showWork?.cancel(); showWork = nil
            panel?.orderOut(nil); panel = nil
            forceShow = false
        }
    }

    // CLI: --preview-preparing [seconds] — hold the window without Wine, for screenshots / Reduce Motion checks.
    static func preview(seconds: TimeInterval) {
        begin(bottle: "Preview", force: true)
        RunLoop.main.run(until: Date().addingTimeInterval(max(0.6, seconds)))
        end()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private static func present() {
        if panel == nil {
            let side: CGFloat = 220
            let root = NSHostingView(rootView: PreparingChrome(bottle: bottle))
            root.frame = NSRect(x: 0, y: 0, width: side, height: side)
            let p = NSPanel(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            p.contentView = root
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.center()
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

private struct PreparingChrome: View {
    let bottle: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // COSMO_TEST_REDUCE_MOTION=1: preview the pulse path without flipping the Mac's Accessibility setting.
    private var stillOutline: Bool { reduceMotion || ProcessInfo.processInfo.environment["COSMO_TEST_REDUCE_MOTION"] == "1" }

    // Icon art is 824×824 with corner radius 160 in the sketch → same ratio on the drawn outline.
    private let side: CGFloat = 160
    private var radius: CGFloat { side * (160.0 / 824.0) }

    var body: some View {
        ZStack {
            Cosmo.background
            glass
            outline
        }
        .frame(width: 220, height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing \(bottle)")
    }

    private var glass: some View {
        Group {
            if let url = Bundle.main.url(forResource: "cosmos-glass-1024", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else { Color.clear }
        }
        .frame(width: side * 0.72, height: side * 0.72)
    }

    @ViewBuilder private var outline: some View {
        // Thin outer track + thick "snake" on a path inset 2 pt so it rides inside the outer line (never swings off).
        let inset: CGFloat = 2
        let outer = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let innerR = max(0, radius - inset)
        let snake = RoundedRectangle(cornerRadius: innerR, style: .continuous)
        if stillOutline {
            outer.stroke(Cosmo.textPrimary, lineWidth: 1.5)
                .frame(width: side, height: side)
                .opacity(0.55)
                .modifier(PreparingPulse())
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let span: CGFloat = 0.22   // ~¼ of the perimeter
                ZStack {
                    outer.stroke(Cosmo.rule, lineWidth: 1)
                        .frame(width: side, height: side)
                    // Trim advances along the rounded-rect path itself (snake). Wrap with a second stroke when it crosses 0.
                    snake.trim(from: phase, to: min(1, phase + span))
                        .stroke(Cosmo.textPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: side - inset * 2, height: side - inset * 2)
                    if phase + span > 1 {
                        snake.trim(from: 0, to: phase + span - 1)
                            .stroke(Cosmo.textPrimary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .frame(width: side - inset * 2, height: side - inset * 2)
                    }
                }
                .frame(width: side, height: side)
            }
        }
    }
}

private struct PreparingPulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { on = true } }
    }
}
