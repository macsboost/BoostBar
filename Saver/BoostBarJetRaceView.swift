import ScreenSaver
import SceneKit

/// BoostBar Jet Racers: three jet racers (#16, #8 and #3) race a new buoy course every couple of minutes, and the
/// winner spins out and celebrates. Drawn natively with SceneKit (Metal) — Saver/native/JetRace.swift — from the same
/// race script the Windows saver runs (Saver/src/jetrace.js). The three.js page (saver.html) is in the bundle for
/// BoostBar's own Preview window.
@objc(BoostBarJetRaceView)
final class BoostBarJetRaceView: ScreenSaverView {
    static let scene = "jetrace"
    static let moduleName = "com.macsboost.boostbar.jetrace"
    static let title = "BoostBar Jet Racers"

    private var sheet: NSWindow?
    private var popups: [String: NSPopUpButton] = [:]
    private var boardCheck: NSButton?
    private var captionsCheck: NSButton?

    private var defaults: UserDefaults {
        let d = ScreenSaverDefaults(forModuleWithName: Self.moduleName) ?? UserDefaults.standard
        d.register(defaults: ["winner": "random", "celebration": "random", "camera": "director", "follow": "leader", "board": true, "captions": false])
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

    /// Options saved by BoostBar ▸ Settings ▸ Screen Saver, beside the installed savers (the real home folder — this
    /// runs inside the screen saver host's container). Used when newer than this saver's own Options sheet.
    private func boostBarOptions() -> [String: Any]? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        let url = URL(fileURLWithPath: String(cString: dir)).appendingPathComponent("Library/Screen Savers/BoostBar Screen Savers.json")
        guard let data = try? Data(contentsOf: url),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let o = all[Self.scene] as? [String: Any] else { return nil }
        if defaults.double(forKey: "savedAt") > (o["savedAt"] as? Double ?? 0) { return nil }   // the Options sheet is newer
        return o
    }

    private func config() -> JetRaceConfig {
        var c = JetRaceConfig()
        if let o = boostBarOptions() {
            c.winner = o["winner"] as? String ?? c.winner
            c.celebration = o["celebration"] as? String ?? c.celebration
            c.camera = o["camera"] as? String ?? c.camera
            c.follow = o["follow"] as? String ?? c.follow
            c.board = o["board"] as? Bool ?? c.board
            c.captions = o["captions"] as? Bool ?? c.captions
        } else {
            let d = defaults
            c.winner = d.string(forKey: "winner") ?? c.winner
            c.celebration = d.string(forKey: "celebration") ?? c.celebration
            c.camera = d.string(forKey: "camera") ?? c.camera
            c.follow = d.string(forKey: "follow") ?? c.follow
            c.board = d.bool(forKey: "board")
            c.captions = d.bool(forKey: "captions")
        }
        if isPreview { c.board = false; c.captions = false }   // the little preview in System Settings is too small for a scoreboard
        return c
    }

    private var sceneView: SCNView?
    private var race: JetRace?
    private var status: NSTextField?

    private func loadScene() {
        sceneView?.removeFromSuperview()
        status?.removeFromSuperview(); status = nil
        guard let res = Bundle(for: type(of: self)).resourceURL else { show("\(Self.title): its bundle is missing resources."); return }
        let r = JetRace(cfg: config(), resources: res)
        let v = SCNView(frame: bounds, options: [SCNView.Option.preferredRenderingAPI.rawValue: NSNumber(value: SCNRenderingAPI.metal.rawValue)])
        v.autoresizingMask = [.width, .height]
        v.scene = r.scene
        v.pointOfView = r.camera
        v.delegate = r
        v.backgroundColor = .black
        v.antialiasingMode = isPreview ? .none : .multisampling4X
        v.preferredFramesPerSecond = isPreview ? 30 : 60
        v.rendersContinuously = true
        v.isPlaying = true
        addSubview(v)
        sceneView = v
        race = r
        sizeChanged()
        if let e = r.error { show("\(Self.title) couldn't start: \(e). Reinstall it from BoostBar ▸ Settings ▸ Screen Saver.") }
    }

    private func sizeChanged() {
        race?.setView(size: bounds.size, scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        sizeChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sizeChanged()
    }

    /// A small message in the middle of the screen instead of a blank one.
    private func show(_ text: String) {
        status?.removeFromSuperview()
        let t = NSTextField(wrappingLabelWithString: text)
        t.textColor = NSColor(white: 0.8, alpha: 1)
        t.font = .systemFont(ofSize: isPreview ? 9 : 18, weight: .medium)
        t.alignment = .center
        let w = min(bounds.width - 40, 760)
        t.frame = NSRect(x: (bounds.width - w) / 2, y: bounds.midY - 40, width: w, height: 80)
        t.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(t)
        status = t
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func startAnimation() {
        super.startAnimation()
        race?.paused = false
        sceneView?.isPlaying = true
    }

    override func stopAnimation() {
        super.stopAnimation()
        race?.paused = true
        sceneView?.isPlaying = false
    }

    override func animateOneFrame() {}   // SceneKit drives the frames

    // MARK: Options sheet

    override var hasConfigureSheet: Bool { true }

    private static let choices: [(key: String, label: String, items: [(id: String, name: String)])] = [
        ("winner", "Winner", JetRaceConfig.winners), ("celebration", "Celebration", JetRaceConfig.celebrations),
        ("camera", "Camera", JetRaceConfig.cameras), ("follow", "Follow", JetRaceConfig.follows),
    ]

    override var configureSheet: NSWindow? {
        let height: CGFloat = 300
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = Self.title
        let v = NSView(frame: w.contentRect(forFrameRect: w.frame))
        var y: CGFloat = height - 48
        popups = [:]
        for c in Self.choices {
            let l = NSTextField(labelWithString: c.label); l.frame = NSRect(x: 20, y: y + 3, width: 90, height: 20); v.addSubview(l)
            let p = NSPopUpButton(frame: NSRect(x: 115, y: y, width: 265, height: 26), pullsDown: false)
            p.addItems(withTitles: c.items.map(\.name))
            p.selectItem(at: c.items.firstIndex { $0.id == defaults.string(forKey: c.key) } ?? 0)
            v.addSubview(p)
            popups[c.key] = p
            y -= 36
        }
        y -= 2
        let b = NSButton(checkboxWithTitle: "Leaderboard", target: nil, action: nil)
        b.state = defaults.bool(forKey: "board") ? .on : .off
        b.frame = NSRect(x: 20, y: y, width: 340, height: 20); v.addSubview(b); boardCheck = b
        y -= 26
        let cc = NSButton(checkboxWithTitle: "Camera captions", target: nil, action: nil)
        cc.state = defaults.bool(forKey: "captions") ? .on : .off
        cc.frame = NSRect(x: 20, y: y, width: 340, height: 20); v.addSubview(cc); captionsCheck = cc
        let ok = NSButton(title: "OK", target: self, action: #selector(closeSheet(_:)))
        ok.keyEquivalent = "\r"; ok.tag = 1
        ok.frame = NSRect(x: 300, y: 12, width: 80, height: 30); v.addSubview(ok)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 215, y: 12, width: 80, height: 30); v.addSubview(cancel)
        w.contentView = v
        sheet = w
        return w
    }

    @objc private func closeSheet(_ sender: NSButton) {
        if sender.tag == 1 {
            let d = defaults
            for c in Self.choices {
                let i = popups[c.key]?.indexOfSelectedItem ?? 0
                d.set(c.items[max(0, min(i, c.items.count - 1))].id, forKey: c.key)
            }
            d.set(boardCheck?.state == .on, forKey: "board")
            d.set(captionsCheck?.state == .on, forKey: "captions")
            d.set(Date().timeIntervalSince1970, forKey: "savedAt")
            d.synchronize()
            loadScene()
        }
        if let s = sheet { s.sheetParent?.endSheet(s) ?? s.close() }
    }
}
