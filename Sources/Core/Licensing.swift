import SwiftUI

// D3DMetal is Apple's proprietary Game Porting Toolkit: usable only after the user has read Apple's license and accepted it explicitly.
// Acceptance = date + SHA-256 of the License file; a different license (new GPTK) asks again. Not accepted ⇒ d3dmetal is never loaded.
let d3dmetalAcceptFile = support + "/d3dmetal-license.json"
// Terms of Use: shown on first run and again whenever TERMS.txt changes (acceptance = date + SHA-256 of the shipped file).
let termsPath = Bundle.main.path(forResource: "TERMS", ofType: "txt") ?? "", termsAcceptFile = support + "/terms-accepted.json"
func termsHash() -> String { shell("shasum -a 256 \(shq("\(termsPath)")) 2>/dev/null | cut -d' ' -f1") }
func termsAccepted() -> Bool {
    guard let j = try? String(contentsOfFile: termsAcceptFile, encoding: .utf8), let h = j.components(separatedBy: "\"sha256\":\"").dropFirst().first?.components(separatedBy: "\"").first else { return false }
    return !h.isEmpty && h == termsHash()
}
func acceptTerms() { let f = ISO8601DateFormatter(); try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true); try? "{\"accepted\":\"\(f.string(from: Date()))\",\"sha256\":\"\(termsHash())\"}".write(toFile: termsAcceptFile, atomically: true, encoding: .utf8) }
// Apple's license as found in the user's own download: License.pdf (GPTK disk image) or License.rtf (the redist folder). Never a copy of ours.
func d3dmetalLicenseFile() -> String? { ["License.pdf", "License.rtf"].map { driversDir + "/d3dmetal/" + $0 }.first { FileManager.default.fileExists(atPath: $0) } }
func d3dmetalInstalled() -> Bool {
    let d = driversDir + "/d3dmetal"
    return FileManager.default.fileExists(atPath: d + "/wine/x86_64-windows/d3d12.dll") && FileManager.default.fileExists(atPath: d + "/external/D3DMetal.framework/D3DMetal") && d3dmetalLicenseFile() != nil
}
func licenseHash() -> String { d3dmetalLicenseFile().map { shell("shasum -a 256 \(shq("\($0)")) 2>/dev/null | cut -d' ' -f1") } ?? "" }
func checkD3DMetalAccepted() -> Bool {
    guard let j = try? String(contentsOfFile: d3dmetalAcceptFile, encoding: .utf8), let h = j.components(separatedBy: "\"sha256\":\"").dropFirst().first?.components(separatedBy: "\"").first else { return false }
    return !h.isEmpty && h == licenseHash()
}
var d3dmetalOK = checkD3DMetalAccepted()
