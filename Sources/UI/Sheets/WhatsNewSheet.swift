import SwiftUI

extension ContentView {
    // Item 40: a fresh install gets the onboarding; an existing one (terms accepted before, or bottles present) skips it and sees "What's
    // new" once. The test build can open a screen directly (COSMO_TEST_SHEET=onboarding-<n> | whatsnew | advanced | library | settings).
    func firstStart() {
        let t = isTestBuild ? ProcessInfo.processInfo.environment["COSMO_TEST_SHEET"] ?? "" : ""
        if isTestBuild, ProcessInfo.processInfo.environment["COSMO_TEST_LIST"] == "1" { libraryList = true }   // screenshot the list view
        if t.hasPrefix("onboarding-") { UserDefaults.standard.set(Int(t.dropFirst(11)) ?? 0, forKey: "onboardingStep"); showTerms = false; showOnboarding = true; return }
        if t == "whatsnew" { showTerms = false; showWhatsNew = true; return }
        if t == "advanced" { showTerms = false; advancedMode = true; return }
        if t == "library" || t == "settings" { showTerms = false; onboardingDone = true; whatsNewSeen = "2.0"; if t == "settings" { openSettings() }; return }
        if onboardingDone { if termsAccepted() { showWhatsNew = whatsNewSeen != "2.0" } else { showTerms = true }; return }
        if UserDefaults.standard.integer(forKey: "onboardingStep") > 0 { logToFile("first start: resuming the onboarding\n"); showOnboarding = true; return }   // quit midway
        if termsAccepted() || !m.bottles.isEmpty {   // an existing install: the old terms sheet only if it never accepted them
            onboardingDone = true; if termsAccepted() { showWhatsNew = whatsNewSeen != "2.0" } else { showTerms = true }; return
        }
        showOnboarding = true
    }

    @ViewBuilder var whatsNewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's new in Cosmopolitan").font(Cosmo.display(28)).tracking(-0.045 * 28).foregroundStyle(Cosmo.textPrimary)
            Label("One Library with all your games. Each one says Ready, Setting up…, Needs a fix or Won't run, and why.", systemImage: "square.grid.2x2")
            Label("Fix this game: saves a snapshot first, then checks and repairs. The last three snapshots are kept, and you can go back in one click.", systemImage: "wrench.and.screwdriver")
            Label("Steam is never restarted while it downloads or a game runs: it waits, or asks you.", systemImage: "clock")
            Label("Signing in to GOG happens in a window inside the app.", systemImage: "person.crop.circle.badge.checkmark")
            Label("Everything you used before is still there: Settings › Show advanced options.", systemImage: "slider.horizontal.3")
            HStack { Spacer(); Button("Continue") { whatsNewSeen = "2.0"; showWhatsNew = false }.keyboardShortcut(.defaultAction).controlSize(.large).primaryButton() }
        }.labelStyle(AccentIcon()).font(Cosmo.body).foregroundStyle(Cosmo.textPrimary).padding(28).frame(width: 580)
    }
}
