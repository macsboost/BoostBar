#if !APPSTORE
import AppKit
import WebKit

/// The "BoostBar Flying Cars" screen saver shipped inside BoostBar.app: preview it, install it, start it.
enum FlyingCarsSaver {
    static var bundleURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Screen Savers/BoostBar Flying Cars.saver")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/BoostBar Flying Cars.saver")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    /// Hands the .saver to macOS, which asks whether to install it and opens Screen Saver settings.
    static func install() {
        guard let u = bundleURL else {
            Updater.alert("Screen saver missing", "This copy of BoostBar doesn't include the Flying Cars screen saver.")
            return
        }
        NSWorkspace.shared.open(u)
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    static func startNow() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }
}

/// A window that plays the Flying Cars scene, for a quick look before installing.
final class SaverPreviewWindow: NSObject, NSWindowDelegate {
    static let shared = SaverPreviewWindow()
    private var window: NSWindow?

    func show(liveries: [String] = ["macsboost", "yonder", "xxone"]) {
        guard let saver = FlyingCarsSaver.bundleURL else { FlyingCarsSaver.install(); return }
        let html = saver.appendingPathComponent("Contents/Resources/saver.html")
        window?.close()
        let conf = WKWebViewConfiguration()
        let list = liveries.map { "\"\($0)\"" }.joined(separator: ",")
        conf.userContentController.addUserScript(WKUserScript(
            source: "window.SAVER_CONFIG={liveries:[\(list)],count:7,speed:1,stars:true,preview:false};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "BoostBar Flying Cars — Preview"
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
