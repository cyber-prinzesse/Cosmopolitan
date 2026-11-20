import SwiftUI
import Vision

// §8.6 / §8.7 Benchmark and fps history. Under translation nothing exposes a frame counter, but the Metal Performance HUD draws one on
// screen, so a benchmark run enables the HUD, samples the screen every 2 s for a fixed window, and reads the FPS line with Vision text
// recognition. Results (avg, 1% low, driver set, engine, date) go to options/.fps-<exe>.csv; a run that is ≥15 % slower than the
// previous one on the same drivers is flagged and the previous driver set offered via Options.
extension Model {
    static func hudFPS(in png: String) -> Double? {
        guard let img = NSImage(contentsOfFile: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let req = VNRecognizeTextRequest(); req.recognitionLevel = .fast; req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: img).perform([req])
        let obs = (req.results ?? []).compactMap { o -> (String, CGRect)? in o.topCandidates(1).first.map { ($0.string.trimmingCharacters(in: .whitespaces), o.boundingBox) } }
        // The HUD is a two-column table: find the "FPS" label, then the bare number on the same row (same vertical band, to its right).
        guard let label = obs.first(where: { $0.0 == "FPS" || $0.0.hasPrefix("FPS ") }) else { return nil }
        if let r = label.0.range(of: #"[0-9]+(\.[0-9]+)?$"#, options: .regularExpression), label.0 != "FPS" { return Double(label.0[r]) }
        let y = label.1.midY, h = max(label.1.height, 0.01)
        return obs.filter { abs($0.1.midY - y) < h * 0.8 && $0.1.minX > label.1.minX && $0.0.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil }
            .sorted { $0.1.minX < $1.1.minX }.first.flatMap { Double($0.0) }
    }
    func fpsHistoryPath(_ exe: String) -> String { "\(bottlesDir)/\(selected)/options/.fps-\((exe as NSString).lastPathComponent).csv" }
    // Launch with the HUD on, wait for the process, sample for `seconds`, record. The game is left running for the user afterwards.
    func benchmark(_ exe: String, seconds: Int = 90) {
        let hud = "\(bottlesDir)/\(selected)/options/.hud-\((exe as NSString).lastPathComponent)"
        var t = (try? String(contentsOfFile: optionsPath(exe), encoding: .utf8)) ?? Model.optionsTemplate
        if !t.contains("MTL_HUD_ENABLED=1") { t += "\nMTL_HUD_ENABLED=1\n"; saveOptions(exe, t); FileManager.default.createFile(atPath: hud, contents: nil) }
        log += "Benchmark: starting \(appName(exe)) with the Metal HUD; sampling \(seconds) s once it's up. Play normally — results land in the log.\n"
        launch(exe)
        let name = (exe as NSString).lastPathComponent, drivers = (readiness[exe]?.drivers ?? driverList(launchEnvRaw(), bottle: selected)).joined(separator: "+")
        Task { @MainActor in
            for _ in 0..<60 { try? await Task.sleep(nanoseconds: 2_000_000_000); if isRunning(name) { break } }
            try? await Task.sleep(nanoseconds: 20_000_000_000)   // past the loading screen
            var samples: [Double] = []
            let tmp = NSTemporaryDirectory() + "cosmo-bench.png"
            for _ in 0..<(seconds / 2) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                _ = sh("screencapture -x -R0,0,1800,300 \(shq("\(tmp)")) 2>/dev/null")   // the HUD sits top-right; crop the top band of the main display
                if let v = Model.hudFPS(in: tmp), v > 0 { samples.append(v) }
            }
            if FileManager.default.fileExists(atPath: hud) { var t2 = (try? String(contentsOfFile: optionsPath(exe), encoding: .utf8)) ?? ""; t2 = t2.replacingOccurrences(of: "\nMTL_HUD_ENABLED=1\n", with: "\n"); saveOptions(exe, t2); try? FileManager.default.removeItem(atPath: hud) }
            guard samples.count >= 5 else { log += "Benchmark: could not read the HUD (\(samples.count) samples). Is the game fullscreen on the main display?\n"; return }
            let sorted = samples.sorted(), avg = samples.reduce(0, +) / Double(samples.count), low = sorted[max(0, Int(Double(sorted.count) * 0.01))]
            let line = "\(ISO8601DateFormatter().string(from: Date())),\(drivers),\(sh("\(shq("\(wineBin)")) --version 2>/dev/null")),\(String(format: "%.1f", avg)),\(String(format: "%.1f", low)),\(samples.count)"
            let prev = ((try? String(contentsOfFile: fpsHistoryPath(exe), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            try? (prev + [line]).joined(separator: "\n").appending("\n").write(toFile: fpsHistoryPath(exe), atomically: true, encoding: .utf8)
            var out = "Benchmark \(appName(exe)): avg \(String(format: "%.0f", avg)) fps, 1% low \(String(format: "%.0f", low)) fps over \(samples.count) samples on \(drivers).\n"
            if let last = prev.last?.split(separator: ",").map(String.init), last.count >= 5, let pavg = Double(last[3]) {
                let delta = (avg - pavg) / pavg * 100
                out += String(format: "  vs previous run (%@, %.0f fps): %+.0f%%", last[1], pavg, delta)
                if delta <= -15 { out += " — about \(Int(-delta))% slower. Previous drivers: \(last[1]); set DRIVERS=\(last[1].replacingOccurrences(of: "+", with: ",")) in Options to roll back." }
                out += "\n"
            }
            logToFile(out); log += out
        }
    }
    func fpsHistory(_ exe: String) -> String {
        let rows = ((try? String(contentsOfFile: fpsHistoryPath(exe), encoding: .utf8)) ?? "").split(separator: "\n")
        guard !rows.isEmpty else { return "No benchmark runs yet for \(appName(exe)).\n" }
        return "fps history \(appName(exe)):\n" + rows.suffix(10).map { r in let c = r.split(separator: ",").map(String.init); return "  \(c[0].prefix(16))  \(c.count > 3 ? c[3] : "?") avg / \(c.count > 4 ? c[4] : "?") low  on \(c.count > 1 ? c[1] : "?")" }.joined(separator: "\n") + "\n"
    }
}
