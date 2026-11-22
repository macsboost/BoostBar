#if !APPSTORE
import AppKit

/// When BoostBar is opened straight out of the downloaded zip (Downloads, Desktop, a mounted disk…),
/// offer to move it into Applications — so it can update itself, launch at login reliably and
/// isn't run from a randomized App Translocation path.
enum MoveToApplications {
    private static let suppressKey = "moveToApplicationsSuppressed"

    /// Returns true if BoostBar is moving and about to relaunch (the caller should stop launching).
    @discardableResult
    static func offerIfNeeded() -> Bool {
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { return false }
        let original = originalURL(of: current)
        let dir = original.deletingLastPathComponent().standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        if dir == "/Applications" || dir.hasPrefix("/Applications/") || dir == userApps || dir.hasPrefix(userApps + "/") { return false }
        if dir.contains("/DerivedData/") || dir.contains("/.build/") || dir.hasSuffix("/dist") { return false } // dev builds
        if UserDefaults.standard.bool(forKey: suppressKey) { return false }

        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = "Move BoostBar to your Applications folder?"
        a.informativeText = "BoostBar is running from \(friendly(dir)). In Applications it can update itself and start at login reliably.\n\nThe copy in \(friendly(dir)) will be moved to the Trash."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        let r = a.runModal()
        if a.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
        guard r == .alertFirstButtonReturn else { return false }
        return move(from: original)
    }

    private static func friendly(_ dir: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir == home + "/Downloads" { return "Downloads" }
        if dir == home + "/Desktop" { return "the Desktop" }
        if dir.hasPrefix("/Volumes/") { return "the disk image" }
        return dir.replacingOccurrences(of: home, with: "~")
    }

    private static func move(from src: URL) -> Bool {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/BoostBar.app")
        let q = Shell.quote
        // Replace an older copy, copy this one in (keeping its signature), clear the download quarantine.
        let script = "rm -rf \(q(dest.path)) && /usr/bin/ditto \(q(src.path)) \(q(dest.path)) && /usr/bin/xattr -dr com.apple.quarantine \(q(dest.path))"
        var ok = Shell.run("/bin/sh", ["-c", script]).status == 0
        if !ok {
            ok = Shell.runAsAdmin(script, prompt: "BoostBar needs your password to move itself into Applications.")
        }
        guard ok, fm.fileExists(atPath: dest.appendingPathComponent("Contents/MacOS/BoostBar").path) else {
            Updater.alert("Couldn't move BoostBar", "Drag BoostBar into your Applications folder in Finder, then open it from there.")
            return false
        }
        try? fm.trashItem(at: src, resultingItemURL: nil) // read-only disk images just stay put

        // Relaunch from Applications once this copy has quit.
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(q(dest.path))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", relaunch]
        try? p.run()
        NSApp.terminate(nil)
        return true
    }

    /// The real location of a translocated app (Gatekeeper runs downloaded apps from a random
    /// read-only path until they're moved). Uses Security.framework's SecTranslocate SPI.
    private static func originalURL(of url: URL) -> URL {
        guard url.path.contains("/AppTranslocation/"),
              let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(h, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
    }
}
#endif
