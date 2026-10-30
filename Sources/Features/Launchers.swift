import SwiftUI

// Item 37: a Dock and Launchpad entry for every game in the Library: a small app in ~/Applications/Cosmopolitan Apps that asks this
// Cosmopolitan to play the game (cosmopolitan://launch?name=…), so every start goes through the launch checks. Kept in sync with the
// Library (launchers of games that are gone are removed; only ours, marked in their Info.plist, are ever touched). Spotlight finds them.
extension Model {
    nonisolated static var launchersDir: String { NSHomeDirectory() + "/Applications/\(appDataName) Apps" }
    nonisolated static let launcherMark = "CosmopolitanLauncher"
    // A launcher's file name, which Launchpad and System Settings show: Finder turns ":" into "/" ("The Witcher 3/ Wild Hunt") and
    // "/" can't be in a name at all. The Beta's launchers say "(Beta)", or two "Steam"s sit side by side. Old names are replaced on
    // the next sync (they are ours and no longer wanted).
    nonisolated static func launcherFileName(_ game: String) -> String {
        let s = game.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "/", with: "-")
        return isBetaBuild ? s + " (Beta)" : s
    }
    func syncLaunchers() {
        let games = library.map { (name: appName($0), icon: icons[$0].flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) }
        let me = Bundle.main.bundlePath
        Task.detached(priority: .utility) { let r = Model.writeLaunchers(games, app: me); if !r.isEmpty { await MainActor.run { self.log += r } } }
    }
    nonisolated static func writeLaunchers(_ games: [(name: String, icon: Data?)], app: String) -> String {
        let fm = FileManager.default, dir = launchersDir; try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var made: [String] = [], gone: [String] = []
        let wanted = Set(games.map { launcherFileName($0.name) })
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") && !wanted.contains(String(f.dropLast(4))) {
            let p = "\(dir)/\(f)"
            if (NSDictionary(contentsOfFile: p + "/Contents/Info.plist")?[launcherMark] as? Bool) == true { try? fm.removeItem(atPath: p); gone.append(String(f.dropLast(4))) }
        }
        for g in games {
            let safe = launcherFileName(g.name), p = "\(dir)/\(safe).app"
            if fm.fileExists(atPath: p + "/Contents/MacOS/launch") { continue }
            try? fm.createDirectory(atPath: p + "/Contents/MacOS", withIntermediateDirectories: true); try? fm.createDirectory(atPath: p + "/Contents/Resources", withIntermediateDirectories: true)
            let url = "cosmopolitan://launch?name=" + (g.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? g.name)
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            fm.createFile(atPath: p + "/Contents/MacOS/launch", contents: Data("#!/bin/sh\n# Plays \(g.name) through Cosmopolitan (launch checks included).\nopen -a \(q(app)) \(q(url)) 2>/dev/null || open \(q(url))\n".utf8), attributes: [.posixPermissions: 0o755])
            var icon = ""
            if let png = g.icon, (try? png.write(to: URL(fileURLWithPath: p + "/Contents/Resources/icon.png"))) != nil {
                _ = shell("/usr/bin/sips -s format icns \(q(p + "/Contents/Resources/icon.png")) --out \(q(p + "/Contents/Resources/icon.icns")) >/dev/null 2>&1; rm -f \(q(p + "/Contents/Resources/icon.png"))")
                icon = "<key>CFBundleIconFile</key><string>icon</string>"
            }
            let id = "local.cosmopolitan.launcher." + safe.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
            let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleName</key><string>\(safe)</string><key>CFBundleExecutable</key><string>launch</string><key>CFBundleIdentifier</key><string>\(id)</string><key>CFBundlePackageType</key><string>APPL</string><key>LSApplicationCategoryType</key><string>public.app-category.games</string><key>\(launcherMark)</key><true/>\(icon)</dict></plist>"
            try? plist.write(toFile: p + "/Contents/Info.plist", atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/codesign --force --sign - \(q(p)) >/dev/null 2>&1")
            made.append(safe)
        }
        return (made.isEmpty ? "" : "Dock and Launchpad entries added: \(made.joined(separator: ", ")).\n") + (gone.isEmpty ? "" : "Entries of removed games taken away: \(gone.joined(separator: ", ")).\n")
    }
}
