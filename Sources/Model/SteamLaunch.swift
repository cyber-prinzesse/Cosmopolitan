import SwiftUI

extension Model {
    func launchCmd(_ exe: String) -> (String, [String]) {
        if let g = steamGames[exe], let r = exe.range(of: "/steamapps/") {
            let steam = String(exe[..<r.lowerBound]) + "/steam.exe"
            // Args after -applaunch <id> are forwarded to the game; Steam keeps its own -cef-* on steam.exe.
            return (winPath(steam), extraArgs(steam) + ["-applaunch", g.id] + extraArgs(exe))
        }
        return (winPath(exe), extraArgs(exe))
    }
}
