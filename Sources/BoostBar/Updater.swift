import AppKit
import ServiceManagement
import Security

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Checks GitHub Releases for a newer build and can install it in place.
final class Updater {
    static let repo = "macsboost/BoostBar"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }
    static var repoPage: URL { URL(string: "https://github.com/\(repo)")! }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    #if !APPSTORE
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let body: String?
        let assets: [Asset]
    }

    private var checking = false

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BoostBar/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, status == 200, let data,
                      let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    if userInitiated {
                        let why = err?.localizedDescription ?? (status == 404 ? "No releases published yet." : "GitHub returned HTTP \(status).")
                        Self.alert("Couldn't check for updates", why)
                    }
                    return
                }
                self.handle(release, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handle(_ release: Release, userInitiated: Bool) {
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard Self.isVersion(latest, newerThan: Self.currentVersion) else {
            if userInitiated { Self.alert("You're up to date", "BoostBar \(Self.currentVersion) is the latest version.") }
            return
        }

        let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") })
        let canInstall = asset != nil && Self.canReplaceSelf

        if !userInitiated, Prefs.autoUpdate, canInstall, let asset, let url = URL(string: asset.browser_download_url) {
            install(from: url, quiet: true, version: latest)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "BoostBar \(latest) is available"
        var info = "You have \(Self.currentVersion)."
        if let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            info += "\n\n" + String(body.prefix(600))
        }
        a.informativeText = info
        if canInstall { a.addButton(withTitle: "Install & Relaunch") }
        a.addButton(withTitle: "View Release")
        a.addButton(withTitle: "Later")
        if canInstall {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Install future updates automatically"
            a.suppressionButton?.state = Prefs.autoUpdate ? .on : .off
        }

        let r = a.runModal()
        if canInstall { Prefs.autoUpdate = a.suppressionButton?.state == .on }
        if canInstall, r == .alertFirstButtonReturn, let asset, let url = URL(string: asset.browser_download_url) {
            install(from: url, quiet: false, version: latest)
        } else if (canInstall && r == .alertSecondButtonReturn) || (!canInstall && r == .alertFirstButtonReturn) {
            NSWorkspace.shared.open(URL(string: release.html_url) ?? Self.releasesPage)
        }
    }

    /// False when running from a read-only/translocated location (e.g. straight from Downloads).
    static var canReplaceSelf: Bool {
        let dir = Bundle.main.bundleURL.deletingLastPathComponent().path
        return Bundle.main.bundleURL.pathExtension == "app"
            && !dir.contains("/AppTranslocation/")
            && FileManager.default.isWritableFile(atPath: dir)
    }

    /// The download must be Apple-notarized and signed by the same team as the running copy.
    private static func isTrusted(_ app: URL) -> Bool {
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0,
              Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status == 0 else { return false }
        func team(_ u: URL) -> String? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(u as CFURL, [], &code) == errSecSuccess, let code else { return nil }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let d = info as? [String: Any] else { return nil }
            return d[kSecCodeInfoTeamIdentifier as String] as? String
        }
        guard let newTeam = team(app) else { return false }
        // An unsigned/ad-hoc dev build has no team; then just require notarization.
        if let mine = team(Bundle.main.bundleURL) { return mine == newTeam }
        return true
    }

    private func install(from url: URL, quiet: Bool, version: String) {
        if quiet {
            DispatchQueue.main.async {
                if let screen = NSScreen.main {
                    Toast.shared.show("Updating to \(version)…", symbol: "arrow.down.circle.fill", near: .topRight, on: screen)
                }
            }
        }
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("BoostBarUpdate-\(UUID().uuidString)")
            let zip = work.appendingPathComponent("BoostBar.zip")
            let newApp = work.appendingPathComponent("BoostBar.app")
            var ok = false
            if let tmp, err == nil {
                do {
                    try fm.createDirectory(at: work, withIntermediateDirectories: true)
                    try fm.moveItem(at: tmp, to: zip)
                    ok = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]).status == 0
                        && fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/BoostBar").path)
                        && Self.isTrusted(newApp)
                } catch { ok = false }
            }
            DispatchQueue.main.async {
                guard ok else {
                    try? fm.removeItem(at: work)
                    if quiet { return }   // try again next launch; don't nag
                    Self.alert("Update failed", err?.localizedDescription ?? "The download couldn't be verified as a notarized MacsBoost build.")
                    return
                }
                Self.swapAndRelaunch(newApp: newApp, scratch: work)
            }
        }.resume()
    }

    private static func swapAndRelaunch(newApp: URL, scratch: URL) {
        let dest = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        DEST=\(Shell.quote(dest))
        NEW=\(Shell.quote(newApp.path))
        if mv "$DEST" "$DEST.old" 2>/dev/null; then
          if /usr/bin/ditto "$NEW" "$DEST"; then rm -rf "$DEST.old"; else rm -rf "$DEST"; mv "$DEST.old" "$DEST"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        rm -rf \(Shell.quote(scratch.path))
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("boostbar-update-\(pid).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [scriptURL.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
        } catch {
            alert("Update failed", error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    #endif

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
