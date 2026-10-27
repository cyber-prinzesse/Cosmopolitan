import SwiftUI
import Carbon

// §9.2 US keyboard layout for games. Wine's Mac driver has no layout switch of its own, but it follows the input source macOS has selected,
// so the switch lives here: select the US layout when a game starts, restore the previous one when it exits. On by default for every game —
// PC games assume US/QWERTY, and other layouts (QWERTZ, AZERTY, UK, Cyrillic, …) move WASD or hotkeys. Options US_KEYBOARD=0 opts a game out
// (US_KEYBOARD=1 is still accepted, and a no-op since it's the default).
extension Model {
    private static func inputSourceID(_ s: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    static func currentLayoutID() -> String { inputSourceID(TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()) }
    @discardableResult static func selectLayout(_ id: String) -> Bool {
        guard let list = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource], let s = list.first else { return false }
        TISEnableInputSource(s)
        return TISSelectInputSource(s) == noErr
    }
    func forceKeyboardLayout(_ exe: String) {
        let before = Model.currentLayoutID()
        // On for every game unless opted out; skip when the layout is already US/ABC (nothing to convert).
        guard options(exe)["US_KEYBOARD"] != "0", !before.hasSuffix(".US"), !before.hasSuffix(".ABC") else { return }
        guard Model.selectLayout("com.apple.keylayout.US") else { log += "Keyboard: could not select the US layout.\n"; return }
        log += "Keyboard: US layout while \(appName(exe)) runs (was \(before.components(separatedBy: ".").last ?? before)); restored on exit.\n"
        whenExits(exe) { Model.selectLayout(before); self.log += "Keyboard: layout restored to \(before.components(separatedBy: ".").last ?? before).\n" }
    }
}
