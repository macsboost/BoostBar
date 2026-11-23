#if !APPSTORE
import AppKit
import WebKit

/// Screen saver options, edited in BoostBar ▸ Settings ▸ Screen Saver and written to
/// ~/Library/Screen Savers/BoostBar Screen Savers.json, next to the installed savers, where the screen saver host
/// (legacyScreenSaver) can read them. (Its own Options sheet doesn't always appear on macOS 26 and later.)
struct SaverOptions: Codable {
    var count: Int
    var speed: Double = 1
    var flapSpeed: Double = 1
    var stunts: Bool = true
    var stars: Bool = true
    var liveries: [String]
    var oxidation: Double = 0.35
    var tilt: Double? = nil   // degrees; nil = the scene's own default
    var crossing: Bool? = nil // Starlink: crossing orbital lanes (X pattern)
    var lasers: Bool? = nil   // Starlink: laser links between nearby satellites
    var clouds: Bool? = nil   // Flying Cars: daytime sky with clouds
    var roadster: Bool? = nil // Starships: the red roadster with a spacesuited driver
    var roadsterStable: Bool? = nil // …flying level with the ships instead of tumbling
    var savedAt: Double = 0
}

enum SaverConfig {
    /// The real home folder (not a container), so the app and the screen saver agree on the path.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var url: URL { realHome.appendingPathComponent("Library/Screen Savers/BoostBar Screen Savers.json") }

    static func defaults(for scene: String) -> SaverOptions {
        switch scene {
        case "starships": return SaverOptions(count: 6, liveries: [])
        case "starlink": return SaverOptions(count: 5, liveries: ["v2", "v3", "deploy"])
        default: return SaverOptions(count: 7, liveries: ["macsboost", "yonder", "xxone"])
        }
    }

    static func defaultTilt(for scene: String) -> Double {
        switch scene { case "starships": return -11.5; case "starlink": return -66; default: return -32 }
    }

    static func all() -> [String: SaverOptions] {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: SaverOptions].self, from: d) else { return [:] }
        return m
    }

    static func options(for scene: String) -> SaverOptions { all()[scene] ?? defaults(for: scene) }

    static func save(_ o: SaverOptions, for scene: String) {
        var m = all()
        var o = o
        o.savedAt = Date().timeIntervalSince1970
        m[scene] = o
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
    }

    /// `window.SAVER_CONFIG = …` for a page.
    static func script(for scene: String) -> String {
        let o = options(for: scene)
        let livs = o.liveries.map { "\"\($0)\"" }.joined(separator: ",")
        return "window.SAVER_CONFIG={liveries:[\(livs)],count:\(o.count),speed:\(o.speed),flapSpeed:\(o.flapSpeed),stunts:\(o.stunts),stars:\(o.stars),oxidation:\(o.oxidation),crossing:\(o.crossing ?? false),lasers:\(o.lasers ?? false),clouds:\(o.clouds ?? false),roadster:\(o.roadster ?? false),roadsterStable:\(o.roadsterStable ?? false),tilt:\(o.tilt ?? defaultTilt(for: scene)),preview:false};"
    }
}

/// The screen savers shipped inside BoostBar.app (direct edition): preview, install, start.
struct BundledSaver {
    let name: String          // bundle name, as shown in System Settings ▸ Screen Saver
    let scene: String         // "cars" | "starships"
    static let flyingCars = BundledSaver(name: "BoostBar Flying Cars", scene: "cars")
    static let starships = BundledSaver(name: "BoostBar Starships", scene: "starships")
    static let starlink = BundledSaver(name: "BoostBar Starlink", scene: "starlink")
    static let all: [BundledSaver] = [.flyingCars, .starships, .starlink]

    var about: String {
        switch scene {
        case "starships": return "Starships glide across the screen, flaps beating like wings, Raptors glowing."
        case "starlink": return "Starlink V2 and V3 satellites beat their solar wings like birds; some arrive folded and unfurl their arrays."
        default: return "X1 SkyRacers in MacsBoost, Yonder 01 and XXONE 51 liveries, fans spinning."
        }
    }

    /// The choice boxes in Settings: liveries for the cars, V2/V3 for Starlink.
    var choices: [(id: String, name: String)] {
        switch scene {
        case "starlink": return [("v15", "Starlink V1.5"), ("v2", "Starlink V2"), ("v3", "Starlink V3"), ("deploy", "V3 deploying")]
        case "cars": return [("macsboost", "MacsBoost"), ("yonder", "Yonder 01"), ("xxone", "XXONE 51")]
        default: return []
        }
    }

    var bundleURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Screen Savers/\(name).saver")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var installedURL: URL {
        SaverConfig.realHome.appendingPathComponent("Library/Screen Savers/\(name).saver")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
            || FileManager.default.fileExists(atPath: "/Library/Screen Savers/\(name).saver")
    }

    /// Copies the .saver into ~/Library/Screen Savers (replacing an older copy), saves its options file, and opens
    /// the screen saver picker. macOS has no supported way for an app to choose the screen saver, so that's one click.
    func install() {
        guard let u = bundleURL else {
            Updater.alert("Screen saver missing", "This copy of BoostBar doesn't include \(name).")
            return
        }
        let fm = FileManager.default
        let dest = installedURL
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let q = Shell.quote
        let ok = Shell.run("/bin/sh", ["-c", "rm -rf \(q(dest.path)) && /usr/bin/ditto \(q(u.path)) \(q(dest.path)) && /usr/bin/xattr -dr com.apple.quarantine \(q(dest.path)) || true"]).status == 0
        if !ok || !fm.fileExists(atPath: dest.path) {
            NSWorkspace.shared.open(u)   // fall back to the Finder install prompt
            return
        }
        SaverConfig.save(SaverConfig.options(for: scene), for: scene)
        // the screen saver host caches loaded savers; quit it so the new copy is picked up
        _ = Shell.run("/usr/bin/killall", ["legacyScreenSaver"])
        Self.openSettings()
    }

    static func openSettings() {
        // macOS 26 and later keep the screen savers under Wallpaper
        let id = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? "com.apple.Wallpaper-Settings.extension" : "com.apple.ScreenSaver-Settings.extension"
        if let u = URL(string: "x-apple.systempreferences:\(id)") { NSWorkspace.shared.open(u) }
    }

    /// Starts whichever screen saver is chosen in System Settings.
    static func startNow() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }
}

/// A window that plays the Flying Cars scene, for a quick look before installing.
final class SaverPreviewWindow: NSObject, NSWindowDelegate {
    static let shared = SaverPreviewWindow()
    private var window: NSWindow?

    func show(_ which: BundledSaver = .flyingCars) {
        guard let saver = which.bundleURL else { which.install(); return }
        let html = saver.appendingPathComponent("Contents/Resources/saver.html")
        window?.close()
        let conf = WKWebViewConfiguration()
        conf.userContentController.addUserScript(WKUserScript(
            source: SaverConfig.script(for: which.scene),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "\(which.name) — Preview"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.backgroundColor = .black
        let web = WKWebView(frame: w.contentView!.bounds, configuration: conf)
        web.autoresizingMask = [.width, .height]
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        w.contentView?.addSubview(web)
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // stop the WebGL scene
        (window?.contentView?.subviews.first as? WKWebView)?.loadHTMLString("", baseURL: nil)
    }
}
#endif
