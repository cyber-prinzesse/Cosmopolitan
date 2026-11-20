import SwiftUI

// Everything shown in the log pane is also appended to ~/Library/Logs/Cosmopolitan.log (Cosmopolitan Beta.log for the Beta; begun afresh on each app start).
let logPath = NSHomeDirectory() + "/Library/Logs/\(appDataName).log"
let previousLogPath = NSHomeDirectory() + "/Library/Logs/\(appDataName).previous.log"
let logFile: FileHandle? = {   // the app's start begins a fresh log; command-line runs append, so they never wipe the app's log
    // The last session's log is kept as Cosmopolitan.previous.log: a session that ended in trouble (and a reopen) can still be read.
    if !cliMode { try? FileManager.default.removeItem(atPath: previousLogPath); try? FileManager.default.moveItem(atPath: logPath, toPath: previousLogPath) }
    if !cliMode || !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
    let h = FileHandle(forWritingAtPath: logPath); h?.seekToEndOfFile(); return h
}()
func logToFile(_ s: String) { logFile?.write(Data(s.utf8)) }
// True when running a command-line mode: no Steam autostart, no background jobs (a CLI process takes its children down when it exits).
var cliMode = false
// pgrep pattern that cannot match the shell running the pgrep itself: "[S]team.exe" matches "Steam.exe" but not the literal "[S]team.exe".
func pgrepPattern(_ name: String) -> String { name.isEmpty ? name : "[\(name.prefix(1))]\(name.dropFirst())" }
// Run a process to the end and return what it wrote to a Pipe stdout. Never waitUntilExit(): it spins the current run loop, so on the main thread
// queued main-actor work runs in the middle of the wait. That crashed the app ("trying to lock recursively") when the work read d3dmetalOK while
// d3dmetalOK's own lazy initialiser was this wait. The exit handler fires on a background queue, so the semaphore cannot deadlock the main thread.
@discardableResult func runToEnd(_ p: Process) -> Data {
    let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
    guard (try? p.run()) != nil else { return Data() }   // not started: reading the pipe would block forever
    let d = (p.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    done.wait(); return d
}
// Canonical path (symlinks and ".." resolved; keeps /private, which NSString path APIs strip from /private/tmp). The path itself if it doesn't exist.
func realPath(_ p: String) -> String { guard let r = realpath(p, nil) else { return p }; defer { free(r) }; return String(cString: r) }
// Run a tool with an argument list (no shell: paths and names from a bottle stay plain arguments); exit status + output. Any thread.
func runTool(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = o
    let out = String(decoding: runToEnd(p), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (p.isRunning || p.processIdentifier == 0 ? -1 : p.terminationStatus, out)
}
// Steam app ids are plain decimal numbers; anything else in an appmanifest (a Windows program can write one) is not an app id.
func isSteamAppID(_ s: String) -> Bool { !s.isEmpty && s.count <= 12 && s.allSatisfy { ("0"..."9").contains($0) } }
// Run a shell command and return its output; usable from any thread.
func shell(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    let o = Pipe(); p.standardOutput = o; p.standardError = o
    return String(decoding: runToEnd(p), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
