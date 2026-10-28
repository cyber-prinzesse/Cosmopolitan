import SwiftUI
import Carbon

// §9.2 Keyboard layout for games. Wine's Mac driver has no layout switch of its own, but it follows the input source macOS has selected,
// so the switch lives here: when a game starts, pick a QWERTY Latin layout, restore the previous one when it exits. PC games assume
// US/QWERTY, and other layouts (QWERTZ, AZERTY, Cyrillic, …) move WASD or hotkeys. The layout is adapted from the input sources the user
// already has enabled (US, ABC, then any other ASCII-capable one); nothing is added to their input menu. Only when none is enabled is
// US enabled for the session, and disabled again on exit. Options US_KEYBOARD=0 opts a game out (US_KEYBOARD=1 is the default).
extension Model {
    private static func inputSourceID(_ s: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    private static func flag(_ s: TISInputSource, _ key: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(s, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
    private static func source(_ id: String, includeAllInstalled: Bool) -> TISInputSource? {
        (TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource])?.first
    }
    static func currentLayoutID() -> String { inputSourceID(TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()) }
    // Keyboard layouts in the user's input menu, in menu order.
    static func enabledLayoutIDs() -> [String] {
        let list = TISCreateInputSourceList([kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return list.filter { flag($0, kTISPropertyInputSourceIsSelectCapable) && flag($0, kTISPropertyInputSourceIsASCIICapable) }.map(inputSourceID)
    }
    // Selects an input source the user already has enabled; never adds one to the input menu.
    @discardableResult static func selectLayout(_ id: String) -> Bool {
        guard let s = source(id, includeAllInstalled: false) else { return false }
        return TISSelectInputSource(s) == noErr
    }
    // The best game layout among the enabled ones: US/ABC first, then other QWERTY Latin layouts, then the current one if it's Latin.
    static func gameLayout(current: String) -> String? {
        let enabled = enabledLayoutIDs()
        let preferred = ["com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.USExtended",
                         "com.apple.keylayout.USInternational-PC", "com.apple.keylayout.ABC-India", "com.apple.keylayout.British", "com.apple.keylayout.British-PC",
                         "com.apple.keylayout.Australian", "com.apple.keylayout.Canadian", "com.apple.keylayout.Irish"]
        if let p = preferred.first(where: enabled.contains) { return p }
        return enabled.contains(current) ? current : enabled.first
    }
    func forceKeyboardLayout(_ exe: String) {
        let before = Model.currentLayoutID()
        guard options(exe)["US_KEYBOARD"] != "0" else { return }
        let short = { (id: String) in id.components(separatedBy: ".").last ?? id }
        if let target = Model.gameLayout(current: before) {
            guard target != before else { return }   // already on a suitable layout
            guard Model.selectLayout(target) else { log += "Keyboard: could not select \(short(target)).\n"; return }
            log += "Keyboard: \(short(target)) while \(appName(exe)) runs (was \(short(before))); restored on exit.\n"
            whenExits(exe) { Model.selectLayout(before); self.log += "Keyboard: layout restored to \(short(before)).\n" }
            return
        }
        // No Latin layout enabled at all: borrow US for this session only, and take it out of the input menu again afterwards.
        guard let us = Model.source("com.apple.keylayout.US", includeAllInstalled: true), TISEnableInputSource(us) == noErr, TISSelectInputSource(us) == noErr else {
            log += "Keyboard: no Latin layout enabled and US could not be selected.\n"; return
        }
        log += "Keyboard: US (temporary) while \(appName(exe)) runs (was \(short(before))); removed on exit.\n"
        whenExits(exe) { Model.selectLayout(before); TISDisableInputSource(us); self.log += "Keyboard: layout restored to \(short(before)), US removed.\n" }
    }
}
