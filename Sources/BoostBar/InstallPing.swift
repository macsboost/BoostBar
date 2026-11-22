import Foundation

/// Anonymous install counter. Sends one small JSON POST to biz-cord.com the first time each
/// version runs (event "install" for a new Mac, "update" after an upgrade). No name, email,
/// IP-derived data or hardware serials are sent — only a random ID created on this Mac.
/// Retries on later launches until the server answers 2xx. Can be turned off in the menu.
enum InstallPing {
    static let endpoint = URL(string: "https://biz-cord.com/api/public/boostbar/install")!

    private static let enabledKey = "shareInstallCount"
    private static let idKey = "installID"
    private static let sentVersionKey = "installPingVersion"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func sendIfNeeded() {
        let d = UserDefaults.standard
        guard isEnabled else { return }
        let version = Updater.currentVersion
        let previous = d.string(forKey: sentVersionKey)
        guard previous != version else { return }

        let id: String
        if let existing = d.string(forKey: idKey) { id = existing } else {
            id = UUID().uuidString
            d.set(id, forKey: idKey)
        }

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body: [String: Any] = [
            "app": "BoostBar",
            "event": previous == nil ? "install" : "update",
            "install_id": id,
            "version": version,
            "previous_version": previous ?? NSNull(),
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "arch": arch,
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("BoostBar/\(version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { _, resp, _ in
            guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return }
            DispatchQueue.main.async { d.set(version, forKey: sentVersionKey) }
        }.resume()
    }
}
