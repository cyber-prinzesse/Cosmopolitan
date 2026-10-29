import SwiftUI

// §9.6 Multi-user Macs: a shared bottle lives in /Users/Shared/Cosmopolitan Bottles and is linked into each user's bottle list.
// Game files are shared once; Wine keeps saves per macOS user automatically (drive_c/users/<username>). Options and the Wine
// registry are per bottle, so they are shared too — the honest limit of a shared prefix.
extension Model {
    nonisolated static var sharedRoot: String { isTestBuild ? support + "/shared-bottles" : "/Users/Shared/\(appDataName) Bottles" }   // the test build never sees real shared bottles
    func shareBottle() {
        let name = selected, src = "\(bottlesDir)/\(name)", dst = "\(Model.sharedRoot)/\(name)"
        guard !name.isEmpty, (try? FileManager.default.destinationOfSymbolicLink(atPath: src)) == nil else { log += "Share: \(name) is already a link (shared or on a drive).\n"; return }
        guard sh("ps -axo command= | grep -c '\\.exe'").hasPrefix("0") else { log += "Share: quit Steam and games in this bottle first.\n"; return }
        busy = true; log += "Sharing \(name) with other users of this Mac… (moved to \(Model.sharedRoot), group-writable, linked back)\n"
        Task.detached {
            let r = shell("mkdir -p '\(Model.sharedRoot)' && mv '\(src)' '\(dst)' && chmod -R +a 'group:staff allow read,write,execute,delete,add_file,add_subdirectory,file_inherit,directory_inherit' '\(dst)' 2>/dev/null; chmod -R g+rwX '\(dst)' && ln -s '\(dst)' '\(src)' && echo shared")
            await MainActor.run { self.busy = false; self.log += r.hasSuffix("shared") ? "Shared. Other users see it after opening Cosmopolitan once; their saves stay in their own Windows user folder.\n" : "Share failed: \(r)\n"; self.refresh() }
        }
    }
    func linkSharedBottles() {   // called on refresh: every shared bottle gets a link in this user's list
        for b in (try? FileManager.default.contentsOfDirectory(atPath: Model.sharedRoot)) ?? [] where !b.hasPrefix(".") && !FileManager.default.fileExists(atPath: "\(bottlesDir)/\(b)") {
            try? FileManager.default.createSymbolicLink(atPath: "\(bottlesDir)/\(b)", withDestinationPath: "\(Model.sharedRoot)/\(b)")
            log += "Shared bottle \(b) linked into your list.\n"
        }
    }
}
