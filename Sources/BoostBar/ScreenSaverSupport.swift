#if !APPSTORE
import AppKit
import WebKit

/// The screen savers shipped inside BoostBar.app (direct edition): preview, install, start.
struct BundledSaver {
    let name: String          // bundle name, as shown in System Settings ▸ Screen Saver
    let scene: String         // "cars" | "starships"
    static let flyingCars = BundledSaver(name: "BoostBar Flying Cars", scene: "cars")
    static let starships = BundledSaver(name: "BoostBar Starships", scene: "starships")
    static let starlink = BundledSaver(name: "BoostBar Starlink", scene: "starlink")

    var bundleURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Screen Savers/\(name).saver")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/\(name).saver")
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// Hands the .saver to macOS, which asks whether to install it and opens Screen Saver settings.
    func install() {
        guard let u = bundleURL else {
            Updater.alert("Screen saver missing", "This copy of BoostBar doesn't include \(name).")
            return
        }
        NSWorkspace.shared.open(u)
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") { NSWorkspace.shared.open(u) }
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

    func show(_ which: BundledSaver = .flyingCars, liveries: [String]? = nil) {
        let liveries = liveries ?? (which.scene == "starlink" ? ["v2", "v3"] : ["macsboost", "yonder", "xxone"])
        guard let saver = which.bundleURL else { which.install(); return }
        let html = saver.appendingPathComponent("Contents/Resources/saver.html")
        window?.close()
        let conf = WKWebViewConfiguration()
        let list = liveries.map { "\"\($0)\"" }.joined(separator: ",")
        conf.userContentController.addUserScript(WKUserScript(
            source: "window.SAVER_CONFIG={liveries:[\(list)],count:\(which.scene == "starships" ? 6 : which.scene == "starlink" ? 5 : 7),speed:1,stars:true,preview:false};",
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
