import ScreenSaver
import WebKit

/// BoostBar Flying Cars: X1 SkyRacers in MacsBoost, Yonder and XXONE liveries crossing the screen,
/// flying-toasters style. The scene is a self-contained three.js page (saver.html) in this bundle.
@objc(BoostBarSaverView)
final class BoostBarSaverView: ScreenSaverView {
    static let moduleName = "com.macsboost.boostbar.saver"
    static let allLiveries: [(id: String, name: String)] = [("macsboost", "MacsBoost"), ("yonder", "Yonder 01"), ("xxone", "XXONE 51")]

    private var web: WKWebView?
    private var sheet: NSWindow?
    private var checks: [NSButton] = []
    private var countSlider: NSSlider?
    private var speedSlider: NSSlider?
    private var starsCheck: NSButton?

    private var defaults: UserDefaults {
        let d = ScreenSaverDefaults(forModuleWithName: Self.moduleName) ?? UserDefaults.standard
        d.register(defaults: ["liveries": "macsboost,yonder,xxone", "count": 7, "speed": 1.0, "stars": true])
        return d
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        loadScene()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        loadScene()
    }

    private func configJS() -> String {
        let d = defaults
        let livs = (d.string(forKey: "liveries") ?? "macsboost,yonder,xxone")
            .split(separator: ",").map { "\"\($0)\"" }.joined(separator: ",")
        return "window.SAVER_CONFIG={liveries:[\(livs)],count:\(d.integer(forKey: "count")),speed:\(d.double(forKey: "speed")),stars:\(d.bool(forKey: "stars")),preview:\(isPreview)};"
    }

    private func loadScene() {
        web?.removeFromSuperview()
        let conf = WKWebViewConfiguration()
        conf.userContentController.addUserScript(WKUserScript(source: configJS(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let w = WKWebView(frame: bounds, configuration: conf)
        w.autoresizingMask = [.width, .height]
        w.setValue(false, forKey: "drawsBackground")
        addSubview(w)
        if let url = Bundle(for: BoostBarSaverView.self).url(forResource: "saver", withExtension: "html") {
            w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        web = w
    }

    override func startAnimation() {
        super.startAnimation()
        web?.evaluateJavaScript("window.__resume && window.__resume()")
    }

    override func stopAnimation() {
        super.stopAnimation()
        web?.evaluateJavaScript("window.__pause && window.__pause()")
    }

    override func animateOneFrame() {}   // the page animates itself

    // MARK: Options sheet

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "BoostBar Flying Cars"
        let v = NSView(frame: w.contentRect(forFrameRect: w.frame))
        var y: CGFloat = 230
        let title = NSTextField(labelWithString: "Liveries")
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: y, width: 200, height: 18); v.addSubview(title)
        let on = Set((defaults.string(forKey: "liveries") ?? "").split(separator: ",").map(String.init))
        checks = []
        for l in Self.allLiveries {
            y -= 24
            let b = NSButton(checkboxWithTitle: l.name, target: nil, action: nil)
            b.identifier = NSUserInterfaceItemIdentifier(l.id)
            b.state = on.contains(l.id) ? .on : .off
            b.frame = NSRect(x: 30, y: y, width: 200, height: 20); v.addSubview(b)
            checks.append(b)
        }
        y -= 36
        let cl = NSTextField(labelWithString: "Flying cars"); cl.frame = NSRect(x: 20, y: y, width: 90, height: 20); v.addSubview(cl)
        let cs = NSSlider(value: Double(defaults.integer(forKey: "count")), minValue: 1, maxValue: 16, target: nil, action: nil)
        cs.frame = NSRect(x: 120, y: y, width: 230, height: 20); v.addSubview(cs); countSlider = cs
        y -= 30
        let sl = NSTextField(labelWithString: "Speed"); sl.frame = NSRect(x: 20, y: y, width: 90, height: 20); v.addSubview(sl)
        let ss = NSSlider(value: defaults.double(forKey: "speed"), minValue: 0.3, maxValue: 3, target: nil, action: nil)
        ss.frame = NSRect(x: 120, y: y, width: 230, height: 20); v.addSubview(ss); speedSlider = ss
        y -= 30
        let st = NSButton(checkboxWithTitle: "Stars in the background", target: nil, action: nil)
        st.state = defaults.bool(forKey: "stars") ? .on : .off
        st.frame = NSRect(x: 20, y: y, width: 250, height: 20); v.addSubview(st); starsCheck = st
        let ok = NSButton(title: "OK", target: self, action: #selector(closeSheet(_:)))
        ok.keyEquivalent = "\r"; ok.tag = 1
        ok.frame = NSRect(x: 280, y: 12, width: 80, height: 30); v.addSubview(ok)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 195, y: 12, width: 80, height: 30); v.addSubview(cancel)
        w.contentView = v
        sheet = w
        return w
    }

    @objc private func closeSheet(_ sender: NSButton) {
        if sender.tag == 1 {
            let d = defaults
            var ids = checks.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }
            if ids.isEmpty { ids = ["macsboost"] }
            d.set(ids.joined(separator: ","), forKey: "liveries")
            d.set(Int(countSlider?.doubleValue ?? 7), forKey: "count")
            d.set(speedSlider?.doubleValue ?? 1, forKey: "speed")
            d.set(starsCheck?.state == .on, forKey: "stars")
            d.synchronize()
            loadScene()
        }
        if let s = sheet { s.sheetParent?.endSheet(s) ?? s.close() }
    }
}
