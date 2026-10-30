import SwiftUI

// §5.2 Cover art for Steam games from Steam's own public CDN (no API key, no account): cached per bottle under art/<appid>.jpg.
extension Model {
    func artPath(_ exe: String) -> String? { steamGames[exe].map { "\(bottlesDir)/\(bottleOf(exe))/art/\($0.id).jpg" } }
    func fetchArt() {
        // Every bottle that has Steam games in the Library (not only the selected one).
        var todo: [(exe: String, id: String, path: String)] = []
        for p in library {
            guard let g = steamGames[p] else { continue }
            let path = "\(bottlesDir)/\(bottleOf(p))/art/\(g.id).jpg"
            if artCache[p] != nil, FileManager.default.fileExists(atPath: path) { continue }
            if FileManager.default.fileExists(atPath: path) {
                // Already on disk from a previous run: decode once off the main thread below, or sync-load into cache.
                todo.append((p, g.id, path)); continue
            }
            todo.append((p, g.id, path))
        }
        guard !todo.isEmpty else { return }
        for t in todo { try? FileManager.default.createDirectory(atPath: (t.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
        Task.detached(priority: .background) {
            var loaded: [(String, NSImage)] = []
            for (exe, id, path) in todo {
                if !FileManager.default.fileExists(atPath: path) {
                    _ = shell("for n in library_600x900.jpg header.jpg library_hero.jpg; do curl -s -m 15 -o '\(path)' -f \"https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/$n\" && break; rm -f '\(path)'; done")
                }
                if let img = NSImage(contentsOfFile: path) { loaded.append((exe, img)) }
            }
            await MainActor.run {
                for (exe, img) in loaded { self.artCache[exe] = img }
                if !loaded.isEmpty { self.artVersion += 1 }
            }
        }
    }
}
