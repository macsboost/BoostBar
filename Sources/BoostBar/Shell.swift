import Foundation
import AppKit

enum Shell {
    /// Runs an executable synchronously and returns its exit status and stdout.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs a shell command as root via the standard macOS admin password prompt.
    /// Must be called on the main thread (NSAppleScript is not thread-safe).
    @discardableResult
    static func runAsAdmin(_ command: String, prompt: String) -> Bool {
        let escapedCmd = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt.replacingOccurrences(of: "\"", with: "'")
        let source = "do shell script \"\(escapedCmd)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    /// Single-quotes a string for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
