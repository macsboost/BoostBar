import ScreenSaver
import SceneKit

/// BoostBar's screen savers, Flying Bread style. One source, two bundles (scripts/build-saver.sh):
///   BoostBar Flying Cars  X1 SkyRacers in MacsBoost, Yonder and XXONE liveries
///   BoostBar Starships    Starships flapping their flaps like the bread's wings (built with -D STARSHIPS)
///   BoostBar Starlink     Starlink V2 / V3 satellites beating their solar wings like birds (built with -D STARLINK)
/// Each draws natively with SceneKit (Metal) — Saver/native/Flock.swift. The three.js page (saver.html) is still in
/// the bundle for BoostBar's own Preview window.
#if STARLINK
@objc(BoostBarStarlinkView)
final class BoostBarStarlinkView: BoostBarSceneView {}
#elseif STARSHIPS
@objc(BoostBarStarshipsView)
final class BoostBarStarshipsView: BoostBarSceneView {}
#else
@objc(BoostBarSaverView)
final class BoostBarSaverView: BoostBarSceneView {}
#endif

class BoostBarSceneView: ScreenSaverView {
    #if STARLINK
    static let scene = "starlink"
    static let moduleName = "com.macsboost.boostbar.starlink"
    static let title = "BoostBar Starlink"
    static let things = "Satellites"
    static let allLiveries: [(id: String, name: String)] = [("v15", "Starlink V1.5"), ("v2", "Starlink V2"), ("v3", "Starlink V3"), ("deploy", "V3 deploying (unfolds its arrays)")]
    static let liveriesTitle = "Satellites to fly"
    static let hasOxidation = false
    static let flapTitle = "Flap speed"
    static let defaultCount = 5
    #elseif STARSHIPS
    static let scene = "starships"
    static let moduleName = "com.macsboost.boostbar.starships"
    static let liveriesTitle = ""
    static let hasOxidation = true
    static let flapTitle = "Flap speed"
    static let title = "BoostBar Starships"
    static let things = "Starships"
    static let allLiveries: [(id: String, name: String)] = []
    static let defaultCount = 6
    #else
    static let scene = "cars"
    static let moduleName = "com.macsboost.boostbar.saver"
    static let title = "BoostBar Flying Cars"
    static let things = "Flying cars"
    static let allLiveries: [(id: String, name: String)] = [("macsboost", "MacsBoost"), ("yonder", "Yonder 01"), ("xxone", "XXONE 51")]
    static let liveriesTitle = "Liveries"
    static let hasOxidation = false
    static let flapTitle = "Fan speed"
    static let defaultCount = 7
    #endif

    private var sheet: NSWindow?
    private var checks: [NSButton] = []
    private var countSlider: NSSlider?
    private var speedSlider: NSSlider?
    private var starsCheck: NSButton?
    private var oxSlider: NSSlider?
    private var flapSlider: NSSlider?
    private var stuntsCheck: NSButton?

    private var defaults: UserDefaults {
        let d = ScreenSaverDefaults(forModuleWithName: Self.moduleName) ?? UserDefaults.standard
        d.register(defaults: ["liveries": Self.allLiveries.map(\.id).joined(separator: ","), "count": Self.defaultCount, "speed": 1.0, "flapSpeed": 1.0, "stunts": true, "stars": true, "oxidation": 0.35])
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

    private func config() -> SaverConfig {
        var c = SaverConfig()
        if let o = boostBarOptions() {
            c.liveries = o["liveries"] as? [String] ?? []
            c.count = o["count"] as? Int ?? Self.defaultCount
            c.speed = o["speed"] as? Double ?? 1
            c.flapSpeed = o["flapSpeed"] as? Double ?? 1
            c.stunts = o["stunts"] as? Bool ?? true
            c.stars = o["stars"] as? Bool ?? true
            c.oxidation = o["oxidation"] as? Double ?? 0.35
            c.tilt = o["tilt"] as? Double
            c.heading = o["heading"] as? Double
            c.crossing = o["crossing"] as? Bool ?? (Self.scene == "starlink")   // Starlink: on unless turned off
            c.lasers = o["lasers"] as? Bool ?? (Self.scene == "starlink")
            c.clouds = o["clouds"] as? Bool ?? false
            c.roadster = o["roadster"] as? Bool ?? (Self.scene == "starships")   // Starman rides along unless turned off
            c.roadsterStable = o["roadsterStable"] as? Bool ?? false
            c.closeEncounter = o["closeEncounter"] as? Bool ?? false
        } else {
            let d = defaults
            c.liveries = (d.string(forKey: "liveries") ?? "").split(separator: ",").map(String.init)
            c.count = d.integer(forKey: "count")
            c.speed = d.double(forKey: "speed")
            c.flapSpeed = d.double(forKey: "flapSpeed")
            c.stunts = d.bool(forKey: "stunts")
            c.stars = d.bool(forKey: "stars")
            c.oxidation = d.double(forKey: "oxidation")
            c.crossing = Self.scene == "starlink"
            c.lasers = Self.scene == "starlink"
            c.roadster = Self.scene == "starships"
        }
        if isPreview { c.count = min(c.count, 5) }
        return c
    }

    private var sceneView: SCNView?
    private var flock: Flock?
    private var status: NSTextField?

    private func loadScene() {
        sceneView?.removeFromSuperview()
        status?.removeFromSuperview(); status = nil
        guard let res = Bundle(for: type(of: self)).resourceURL else { show("\(Self.title): its bundle is missing resources."); return }
        let f = Flock(kind: Flock.Kind(rawValue: Self.scene) ?? .cars, cfg: config(), resources: res)
        let v = SCNView(frame: bounds, options: [SCNView.Option.preferredRenderingAPI.rawValue: NSNumber(value: SCNRenderingAPI.metal.rawValue)])
        v.autoresizingMask = [.width, .height]
        v.scene = f.scene
        v.pointOfView = f.camera
        v.delegate = f
        v.backgroundColor = .black
        v.antialiasingMode = isPreview ? .none : .multisampling4X
        v.preferredFramesPerSecond = isPreview ? 30 : 60
        v.rendersContinuously = true
        v.isPlaying = true
        f.setAspect(bounds.width / max(bounds.height, 1))
        addSubview(v)
        sceneView = v
        flock = f
        if let e = f.error { show("\(Self.title) couldn't load its models: \(e). Reinstall it from BoostBar ▸ Settings ▸ Screen Saver.") }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        flock?.setAspect(bounds.width / max(bounds.height, 1))
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
        flock?.paused = false
        sceneView?.isPlaying = true
    }

    override func stopAnimation() {
        super.stopAnimation()
        flock?.paused = true
        sceneView?.isPlaying = false
    }

    override func animateOneFrame() {}   // SceneKit drives the frames

    // MARK: Options sheet

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let hasLiveries = !Self.allLiveries.isEmpty
        let height: CGFloat = (hasLiveries ? 270 : 170) + (Self.hasOxidation ? 44 : 0) + 60
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = Self.title
        let v = NSView(frame: w.contentRect(forFrameRect: w.frame))
        var y: CGFloat = height - 40
        if hasLiveries {
            let title = NSTextField(labelWithString: Self.liveriesTitle)
            title.font = .boldSystemFont(ofSize: 13)
            title.frame = NSRect(x: 20, y: y, width: 200, height: 18); v.addSubview(title)
        } else {
            y += 26
        }
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
        let cl = NSTextField(labelWithString: Self.things); cl.frame = NSRect(x: 20, y: y, width: 90, height: 20); v.addSubview(cl)
        let cs = NSSlider(value: Double(defaults.integer(forKey: "count")), minValue: 1, maxValue: Self.scene == "starlink" ? 69 : 16, target: nil, action: nil)
        cs.frame = NSRect(x: 120, y: y, width: 230, height: 20); v.addSubview(cs); countSlider = cs
        y -= 30
        let sl = NSTextField(labelWithString: "Speed"); sl.frame = NSRect(x: 20, y: y, width: 90, height: 20); v.addSubview(sl)
        let ss = NSSlider(value: defaults.double(forKey: "speed"), minValue: 0.3, maxValue: 3, target: nil, action: nil)
        ss.frame = NSRect(x: 120, y: y, width: 230, height: 20); v.addSubview(ss); speedSlider = ss
        ss.toolTip = "How fast they fly across the screen"
        y -= 30
        let fl = NSTextField(labelWithString: Self.flapTitle); fl.frame = NSRect(x: 20, y: y, width: 95, height: 20); v.addSubview(fl)
        let fs = NSSlider(value: defaults.double(forKey: "flapSpeed"), minValue: 0.2, maxValue: 3, target: nil, action: nil)
        fs.frame = NSRect(x: 120, y: y, width: 230, height: 20); v.addSubview(fs); flapSlider = fs
        fs.toolTip = Self.flapTitle == "Fan speed" ? "How fast the fans spin" : "How fast they flap"
        y -= 30
        let sc = NSButton(checkboxWithTitle: "Stunts (barrel rolls, veers, climbs and dives)", target: nil, action: nil)
        sc.state = defaults.bool(forKey: "stunts") ? .on : .off
        sc.frame = NSRect(x: 20, y: y, width: 340, height: 20); v.addSubview(sc); stuntsCheck = sc
        y -= 30
        if Self.hasOxidation {
            // re-entry burn on the heat shield: clean black tiles … streaky orange oxidised tiles
            let ol = NSTextField(labelWithString: "Oxidation"); ol.frame = NSRect(x: 20, y: y, width: 90, height: 20); v.addSubview(ol)
            let os = NSSlider(value: defaults.double(forKey: "oxidation"), minValue: 0, maxValue: 1, target: nil, action: nil)
            os.frame = NSRect(x: 120, y: y, width: 230, height: 20); v.addSubview(os); oxSlider = os
            os.toolTip = "How burnt the heat shield looks after re-entry"
            for (t, x, align) in [("Fresh tiles", 120.0, NSTextAlignment.left), ("Post-re-entry", 230.0, .right)] {
                let c = NSTextField(labelWithString: t)
                c.font = .systemFont(ofSize: 10); c.textColor = .secondaryLabelColor; c.alignment = align
                c.frame = NSRect(x: x, y: y - 16, width: 120, height: 14); v.addSubview(c)
            }
            y -= 44
        }
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
            if ids.isEmpty, let first = Self.allLiveries.first { ids = [first.id] }
            if !Self.allLiveries.isEmpty { d.set(ids.joined(separator: ","), forKey: "liveries") }
            d.set(Int(countSlider?.doubleValue ?? Double(Self.defaultCount)), forKey: "count")
            d.set(speedSlider?.doubleValue ?? 1, forKey: "speed")
            d.set(starsCheck?.state == .on, forKey: "stars")
            if let os = oxSlider { d.set(os.doubleValue, forKey: "oxidation") }
            d.set(flapSlider?.doubleValue ?? 1, forKey: "flapSpeed")
            d.set(stuntsCheck?.state == .on, forKey: "stunts")
            d.set(Date().timeIntervalSince1970, forKey: "savedAt")
            d.synchronize()
            loadScene()
        }
        if let s = sheet { s.sheetParent?.endSheet(s) ?? s.close() }
    }
}
