import AppKit
import SceneKit
import simd

/// Options shared by all three screen savers (from BoostBar ▸ Settings ▸ Screen Saver or the Options sheet).
struct SaverConfig {
    var liveries: [String] = []
    var count = 7
    var speed = 1.0
    var flapSpeed = 1.0
    var stunts = true
    var stars = true
    var oxidation = 0.35
    var tilt: Double? = nil
    /// Starlink: fly in two crossing sets of orbital lanes (ascending and descending passes) — an X pattern.
    var crossing = false
    /// Starlink: red laser links between nearby satellites, make-before-break, from the four corner terminals.
    var lasers = false
}

/// BoostBar's flying-toasters screen savers, drawn natively with SceneKit (Metal): the same flock, stunts, bumping,
/// flapping and oxidation as the web version (Saver/src/saver.js), which stays for BoostBar's own Preview window.
final class Flock: NSObject, SCNSceneRendererDelegate {
    enum Kind: String { case cars, starships, starlink }

    let kind: Kind
    let cfg: SaverConfig
    let scene = SCNScene()
    let camera = SCNNode()
    private(set) var error: String?
    private var craft: [Craft] = []
    private var lastTime: TimeInterval?
    private var clock: TimeInterval = 0
    private var aspect: Float = 16.0 / 10.0
    var paused = false

    private let dir = simd_normalize(SIMD3<Float>(-1, -0.52, 0))       // toward the lower left, like the toasters
    private var perp: SIMD3<Float> { SIMD3(-dir.y, dir.x, 0) }
    private var lat: SIMD3<Float> { simd_normalize(perp * 0.45 + SIMD3(0, 0, 0.9)) }
    private let fov: Float = 28
    private var tilt: Float {
        Float((cfg.tilt ?? (kind == .starlink ? -66 : kind == .starships ? -11.5 : -32)) * .pi / 180)
    }

    init(kind: Kind, cfg: SaverConfig, resources: URL) {
        self.kind = kind
        self.cfg = cfg
        super.init()
        setUpStage()
        do { try build(resources) } catch { self.error = "\(error)" }
    }

    func setAspect(_ a: CGFloat) { if a > 0 { aspect = Float(a) } }

    private var closeupZ: Float?

    /// For the CI check: park the first craft in front of the camera and hide the rest.
    func closeup(distance: Float = 30, deploy: Float? = nil) {
        closeupZ = 52 - distance
        if let d = deploy, let c = craft.first { c.dep = d; c.depStarted = false }
        for (i, c) in craft.enumerated() {
            c.g.isHidden = i > 0
            if i == 0 { c.x = 0; c.y = 0; c.z = 52 - distance; c.speed = 0; c.man = nil; c.next = .greatestFiniteMagnitude }
        }
    }

    // MARK: stage

    private func setUpStage() {
        scene.background.contents = NSColor.black
        let cam = SCNCamera()
        cam.fieldOfView = CGFloat(fov)
        cam.projectionDirection = .vertical
        cam.zNear = 1
        cam.zFar = 400
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        let exposure: Float = kind == .starships ? 0.85 : kind == .starlink ? 0.9 : 1.35
        cam.exposureOffset = CGFloat(log2(exposure))
        cam.bloomIntensity = 0
        camera.camera = cam
        camera.simdPosition = SIMD3(0, 0, 52)
        scene.rootNode.addChildNode(camera)

        // sky / ground fill (three.js HemisphereLight ≈ ambient) + a sun + a coloured rim
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 520
        amb.color = NSColor(calibratedRed: 0.85, green: 0.9, blue: 0.85, alpha: 1)
        let a = SCNNode(); a.light = amb; scene.rootNode.addChildNode(a)
        let sun = SCNLight(); sun.type = .directional; sun.intensity = 2100
        let s = SCNNode(); s.light = sun; s.simdPosition = SIMD3(-30, 40, 60); s.simdLook(at: .zero)
        scene.rootNode.addChildNode(s)
        let rim = SCNLight(); rim.type = .directional
        rim.intensity = kind == .cars ? 450 : 650
        rim.color = kind == .starships ? NSColor(calibratedRed: 1, green: 0.69, blue: 0.44, alpha: 1)
            : kind == .starlink ? NSColor(calibratedRed: 0.53, green: 0.67, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.53, green: 1, blue: 0.4, alpha: 1)
        let r = SCNNode(); r.light = rim; r.simdPosition = SIMD3(40, -20, -30); r.simdLook(at: .zero)
        scene.rootNode.addChildNode(r)
        if kind == .starships {
            scene.lightingEnvironment.contents = studioEnvironment()
            scene.lightingEnvironment.intensity = 1.6
        }

        if cfg.stars {
            var pts: [Float] = []
            for _ in 0..<500 {
                pts += [Float.random(in: -150...150), Float.random(in: -100...100), -120 - Float.random(in: 0...60)]
            }
            let src = SCNGeometrySource(data: pts.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: 500,
                                        usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
            let idx = (0..<UInt32(500)).map { $0 }
            let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .point,
                                        primitiveCount: 500, bytesPerIndex: 4)
            el.pointSize = 1.4
            el.minimumPointScreenSpaceRadius = 0.6
            el.maximumPointScreenSpaceRadius = 1.4
            let g = SCNGeometry(sources: [src], elements: [el])
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = NSColor(calibratedRed: 0.53, green: 0.6, blue: 0.67, alpha: 1)
            g.materials = [m]
            scene.rootNode.addChildNode(SCNNode(geometry: g))
        }
    }

    // MARK: craft

    final class Craft {
        let g = SCNNode()
        var fans: [(node: SCNNode, q0: simd_quatf, sg: Float, rate: Float)] = []
        var flaps: [(node: SCNNode, q0: simd_quatf, s: Float, fwd: Bool)] = []
        var wings: [(node: SCNNode, q0: simd_quatf, s: Float, i: Int, n: Int)] = []
        var links: [(node: SCNNode, q0: simd_quatf, s: Float)] = []
        var plume: SCNNode?, core: SCNNode?
        /// Starlink "deploying": arrays start fan-folded on the bus, unfold straight up, lay flat, then flap.
        var deploys = false, dep: Float = 0, depStarted = false
        var x: Float = 0, y: Float = 0, z: Float = 0, speed: Float = 8, phase: Float = 0
        /// Direction of travel (crossing mode gives each lane its own), lane index, and a counter bumped on respawn.
        var d = simd_normalize(SIMD3<Float>(-1, -0.52, 0)), lane = -1, gen = 0
        var terminals: [SCNNode] = []
        var kx: Float = 0, ky: Float = 0, kz: Float = 0, wob: Float = 0
        var spin: Float = .random(in: 0...10), flapRate: Float = 1
        var man: Stunt?
        var next: TimeInterval = 0
    }

    struct Stunt { enum T { case roll, veer, alt }; let type: T; let t0: TimeInterval; let dur: Double; let dirn: Float; let amp: Float }

    private func build(_ res: URL) throws {
        let n = max(1, min(20, cfg.count))
        switch kind {
        case .cars:
            let all = ["macsboost", "yonder", "xxone"]
            var ids = cfg.liveries.filter(all.contains)
            if ids.isEmpty { ids = all }
            var tpl: [String: SCNNode] = [:]
            for id in ids { tpl[id] = try GLB.load(res.appendingPathComponent("X1_\(id).glb")).root }
            for i in 0..<n {
                let c = Craft()
                let root = tpl[ids[i % ids.count]]!.clone()
                c.g.addChildNode(root)
                root.enumerateHierarchy { o, _ in
                    guard let name = o.name else { return }
                    if name.hasPrefix("Rotor_"), !name.contains("__decal") {
                        let up = ["FL_Upper", "FR_Lower", "RR_Upper", "RL_Lower"].contains { name.contains($0) }
                        c.fans.append((o, o.simdOrientation, up ? 1 : -1, 34))
                    } else if name.hasPrefix("Thruster_Fan_"), !name.contains("__decal") {
                        c.fans.append((o, o.simdOrientation, name.hasSuffix("L") ? 1 : -1, 40))
                    }
                }
                add(c)
            }
        case .starships:
            let m = try GLB.load(res.appendingPathComponent("Starship.glb"))
            guard let ship = m.root.childNode(withName: "ship", recursively: true) else { throw GLBError.badFile("no ship node") }
            let b = ship.deepBounds() ?? (SIMD3(0, 0, 0), SIMD3(0, 1, 0))
            let mid = (b.min + b.max) / 2
            ship.removeFromParentNode()
            ship.simdPosition -= mid
            // brushed steel, and the oxidation shader on the hull's heat shield
            ship.enumerateHierarchy { o, _ in
                for mat in o.geometry?.materials ?? [] {
                    mat.isDoubleSided = true
                    if mat.name == "steel" {
                        mat.metalness.contents = 0.92; mat.roughness.contents = 0.26
                        mat.diffuse.contents = NSColor(srgbRed: 0.80, green: 0.81, blue: 0.83, alpha: 1)
                    }
                }
            }
            // the hull's own copy of the tile material (the flaps share the original and stay unburnt)
            for o in [ship] + ship.childNodes where o === ship || o.name?.hasPrefix("ship_") == true {
                guard let g = o.geometry else { continue }
                g.materials = g.materials.map { mat in
                    guard mat.name == "tile" || mat.name == "steel", let own = mat.copy() as? SCNMaterial else { return mat }
                    if mat.name == "tile" { oxidise(own, y0: b.min.y, y1: b.max.y) } else { stainless(own, y0: b.min.y, y1: b.max.y) }
                    return own
                }
            }
            let scale: Float = 0.19
            let pivot = SCNNode()
            pivot.simdEulerAngles = SIMD3(.pi / 2, 0, 0)    // nose (+y) → +z, heat shield (+z) → down
            pivot.simdScale = SIMD3(repeating: scale)
            pivot.addChildNode(ship)
            let tpl = SCNNode()
            tpl.addChildNode(pivot)
            let tail = (b.min.y - mid.y) * scale
            for i in 0..<n {
                let c = Craft()
                let root = tpl.clone()
                c.g.addChildNode(root)
                root.enumerateHierarchy { o, _ in
                    guard let name = o.name, let e = m.extras[name], let kind = e["flap"] as? String else { return }
                    c.flaps.append((o, o.simdOrientation, Float(e["s"] as? Double ?? 1), kind == "fwd"))
                }
                let plume = exhaust(length: plumeLength, width: 1.25)
                plume.simdPosition = SIMD3(0, 0, tail + 0.05)
                let core = glow(inner: NSColor(srgbRed: 0.9, green: 0.94, blue: 1, alpha: 0.9), outer: NSColor(srgbRed: 0.47, green: 0.63, blue: 1, alpha: 0.35), size: 1.0)
                core.simdPosition = SIMD3(0, 0, tail - 0.1)
                root.addChildNode(plume); root.addChildNode(core)
                c.plume = plume; c.core = core
                c.flapRate = 5.2 + .random(in: 0...2.2)
                _ = i
                add(c)
            }
        case .starlink:
            let m = try GLB.load(res.appendingPathComponent("Starlink.glb"))
            var want = cfg.liveries.map { $0.uppercased() }.filter { $0 == "V2" || $0 == "V3" || $0 == "DEPLOY" }
            if want.isEmpty { want = ["V2", "V3", "DEPLOY"] }
            var tpl: [String: SCNNode] = [:]
            for kindName in want {
                let name = kindName == "DEPLOY" ? "V3" : kindName      // the deploying one is a V3, fresh off Starship
                if tpl[name] != nil { continue }
                guard let sat = m.root.childNode(withName: name, recursively: true) else { continue }
                sat.removeFromParentNode()
                sat.enumerateHierarchy { o, _ in o.geometry?.materials.forEach { $0.isDoubleSided = true } }
                let pivot = SCNNode(); pivot.simdScale = SIMD3(repeating: 0.4); pivot.addChildNode(sat)
                let root = SCNNode(); root.addChildNode(pivot)
                tpl[name] = root
            }
            let have = want.filter { tpl[$0 == "DEPLOY" ? "V3" : $0] != nil }
            guard !have.isEmpty else { throw GLBError.badFile("no satellites in Starlink.glb") }
            for i in 0..<n {
                let c = Craft()
                let pick = have[i % have.count]
                c.deploys = pick == "DEPLOY"
                let root = tpl[pick == "DEPLOY" ? "V3" : pick]!.clone()
                c.g.addChildNode(root)
                root.enumerateHierarchy { o, _ in
                    guard let name = o.name, let e = m.extras[name] else { return }
                    if let l = e["link"] as? String { c.links.append((o, o.simdOrientation, l == "R" ? 1 : -1)); return }
                    if e["laser"] != nil { c.terminals.append(o); return }
                    guard let w = e["wing"] as? String else { return }
                    c.wings.append((o, o.simdOrientation, w == "R" ? 1 : -1, e["i"] as? Int ?? 0, e["n"] as? Int ?? 1))
                }
                c.flapRate = 3.6 + .random(in: 0...1.6)
                c.terminals.sort { ($0.name ?? "") < ($1.name ?? "") }
                add(c)
            }
            if cfg.crossing { makeLanes() }
            if cfg.lasers { makeBeamParts() }
        }
    }

    // MARK: crossing lanes

    /// One orbital lane across the screen: a straight line (direction d, sideways offset `off` as a fraction of the
    /// view) at depth z, all its satellites at one speed so they keep their spacing, like a string of Starlinks.
    private struct Lane { var d: SIMD3<Float>; var off: Float; var z: Float; var speed: Float }
    private var lanes: [Lane] = []

    private func laneLength(_ l: Lane) -> Float {
        let (w, h) = viewHalf(l.z)
        return (w * w + h * h).squareRoot() + 24
    }

    private func lanePoint(_ l: Lane, _ s: Float) -> SIMD2<Float> {
        let (_, h) = viewHalf(l.z)
        let k: Float = l.off * h
        let p = SIMD2<Float>(-l.d.y * k, l.d.x * k)
        return p + SIMD2<Float>(l.d.x * s, l.d.y * s)
    }

    private func makeLanes() {
        // ascending and descending passes cross on screen: half the lanes head down-left, half up-left
        let a = simd_normalize(SIMD3<Float>(-1, -0.62, 0)), b = simd_normalize(SIMD3<Float>(-1, 0.62, 0))
        let perDir = max(1, min(4, Int((Double(craft.count) / 4).rounded())))
        for (k, d) in [a, b].enumerated() {
            for i in 0..<perDir {
                let off = perDir == 1 ? Float.random(in: -0.25...0.25) : (Float(i) / Float(perDir - 1) * 2 - 1) * 0.75 + .random(in: -0.1...0.1)
                let z: Float = (k == 0 ? -6 : -20) + .random(in: -8...8)
                lanes.append(Lane(d: d, off: off, z: z, speed: (6 + .random(in: 0...3)) * Float(cfg.speed)))
            }
        }
        lanes.shuffle()
        var members: [[Craft]] = Array(repeating: [], count: lanes.count)
        for (i, c) in craft.enumerated() { members[i % lanes.count].append(c) }
        for (li, group) in members.enumerated() {
            let l = lanes[li], L = laneLength(l)
            for (k, c) in group.enumerated() {
                c.lane = li
                c.d = l.d
                c.z = l.z
                c.speed = l.speed
                let s = -L + 2 * L * (Float(k) + .random(in: 0...0.35)) / Float(group.count)
                let p = lanePoint(l, s)
                c.x = p.x; c.y = p.y
            }
        }
    }

    /// Back to the start of its lane, off the right-hand edge.
    private func relane(_ c: Craft) {
        let l = lanes[c.lane]
        let p = lanePoint(l, -laneLength(l))
        c.x = p.x; c.y = p.y; c.z = l.z
        c.phase = .random(in: 0...(2 * .pi))
        c.dep = 0; c.depStarted = false
        c.man = nil
        c.kx = 0; c.ky = 0; c.kz = 0; c.wob = 0
        c.next = clock + 2 + .random(in: 0...9)
        c.gen += 1
    }

    // MARK: laser links

    /// A red optical link between two satellites' terminals. It grows from one terminal to the other when it's
    /// made and fades when it's dropped; a link is only dropped once both ends hold another (make before break).
    private final class Beam {
        let a: Int, b: Int, ta: Int, tb: Int, ga: Int, gb: Int
        let root = SCNNode(), line: SCNNode, endA: SCNNode, endB: SCNNode
        var grow: Float = 0, fade: Float = 1, dying = false, flick: Float = .random(in: 0...10)
        init(a: Int, b: Int, ta: Int, tb: Int, ga: Int, gb: Int, line: SCNNode, endA: SCNNode, endB: SCNNode) {
            self.a = a; self.b = b; self.ta = ta; self.tb = tb; self.ga = ga; self.gb = gb
            self.line = line; self.endA = endA; self.endB = endB
            root.addChildNode(line); root.addChildNode(endA); root.addChildNode(endB)
        }
    }
    private var beams: [Beam] = []
    private var beamLine: SCNNode?, beamEnd: SCNNode?
    private let makeR: Float = 30, breakR: Float = 40, hardR: Float = 56

    private func makeBeamParts() {
        func tube(_ r: CGFloat, _ color: NSColor) -> SCNNode {
            let g = SCNCylinder(radius: r, height: 1)
            g.radialSegmentCount = 10
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.blendMode = .add
            m.writesToDepthBuffer = false
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.simdPosition = SIMD3(0, 0.5, 0)       // the unit tube runs from 0 to 1 along y
            n.renderingOrder = 20
            return n
        }
        let line = SCNNode()
        line.addChildNode(tube(0.045, NSColor(srgbRed: 1, green: 0.55, blue: 0.5, alpha: 1)))
        line.addChildNode(tube(0.13, NSColor(srgbRed: 1, green: 0.08, blue: 0.05, alpha: 0.55)))
        line.addChildNode(tube(0.32, NSColor(srgbRed: 1, green: 0.02, blue: 0.02, alpha: 0.16)))
        beamLine = line
        beamEnd = glow(inner: NSColor(srgbRed: 1, green: 0.75, blue: 0.7, alpha: 1), outer: NSColor(srgbRed: 1, green: 0.05, blue: 0.03, alpha: 0.5), size: 1.3)
    }

    private func ready(_ c: Craft) -> Bool { c.terminals.count == 4 && !(c.deploys && c.dep < 7.8) }

    private func updateLasers(_ dt: Float) {
        guard cfg.lasers, let lineT = beamLine, let endT = beamEnd else { return }
        func dist(_ i: Int, _ j: Int) -> Float { simd_distance(craft[i].g.simdPosition, craft[j].g.simdPosition) }
        func holdsOther(_ i: Int, _ except: Beam) -> Bool {
            beams.contains { $0 !== except && !$0.dying && $0.grow >= 1 && ($0.a == i || $0.b == i) }
        }
        // keep, drop or retire existing links
        for bm in beams {
            let A = craft[bm.a], B = craft[bm.b]
            if A.gen != bm.ga || B.gen != bm.gb { bm.fade = 0; bm.dying = true; continue }   // one went off screen
            let d = dist(bm.a, bm.b)
            if !bm.dying {
                if !ready(A) || !ready(B) || d > hardR { bm.dying = true }
                else if d > breakR, holdsOther(bm.a, bm), holdsOther(bm.b, bm) { bm.dying = true }
            }
            bm.grow = min(1, bm.grow + dt / 0.35)
            if bm.dying { bm.fade -= dt / 0.45 }
        }
        beams.removeAll { b in
            if b.fade <= 0 { b.root.removeFromParentNode(); return true }
            return false
        }
        // make one new link per frame: the closest pair in range that isn't linked and has free terminals
        func used(_ i: Int) -> Set<Int> {
            var s = Set<Int>()
            for b in beams where !(b.dying && b.fade < 0.5) {
                if b.a == i { s.insert(b.ta) }
                if b.b == i { s.insert(b.tb) }
            }
            return s
        }
        var best: (i: Int, j: Int, d: Float)?
        for i in 0..<craft.count where ready(craft[i]) {
            for j in (i + 1)..<max(i + 1, craft.count) where ready(craft[j]) {
                let d = dist(i, j)
                guard d < makeR, d < (best?.d ?? .infinity) else { continue }
                if beams.contains(where: { !$0.dying && (($0.a == i && $0.b == j) || ($0.a == j && $0.b == i)) }) { continue }
                if used(i).count >= 4 || used(j).count >= 4 { continue }
                best = (i, j, d)
            }
        }
        if let p = best {
            let A = craft[p.i], B = craft[p.j]
            func pick(_ c: Craft, _ ui: Set<Int>, toward: SIMD3<Float>) -> Int {
                (0..<4).filter { !ui.contains($0) }.min { simd_distance(c.terminals[$0].simdWorldPosition, toward) < simd_distance(c.terminals[$1].simdWorldPosition, toward) }!
            }
            let ta = pick(A, used(p.i), toward: B.g.simdPosition), tb = pick(B, used(p.j), toward: A.g.simdPosition)
            let bm = Beam(a: p.i, b: p.j, ta: ta, tb: tb, ga: A.gen, gb: B.gen,
                          line: lineT.clone(), endA: endT.clone(), endB: endT.clone())
            scene.rootNode.addChildNode(bm.root)
            beams.append(bm)
        }
        // draw
        let up = SIMD3<Float>(0, 1, 0)
        for bm in beams {
            let pa = craft[bm.a].terminals[bm.ta].simdWorldPosition, pb = craft[bm.b].terminals[bm.tb].simdWorldPosition
            let v = (pb - pa) * bm.grow
            let len = max(1e-3, simd_length(v))
            bm.line.simdPosition = pa
            bm.line.simdOrientation = simd_quatf(from: up, to: v / len)
            bm.line.simdScale = SIMD3(1, len, 1)
            bm.endA.simdPosition = pa
            bm.endB.simdPosition = pa + v
            bm.endB.isHidden = bm.grow < 1
            bm.flick += dt
            let shimmer = 0.88 + 0.12 * sin(bm.flick * 23) * sin(bm.flick * 7.3)
            bm.root.opacity = CGFloat(max(0, bm.fade) * shimmer)
        }
    }

    private func add(_ c: Craft) {
        spawn(c, initial: true)
        scene.rootNode.addChildNode(c.g)
        craft.append(c)
    }

    private let plumeLength: Float = 5.4

    /// The Raptor exhaust: a long, translucent plume behind the tail (local -z), drawn on four crossed planes so it
    /// reads from any side — blue-white at the nozzles, shock diamonds, then a hot orange tail fading out.
    private func exhaust(length: Float, width: Float) -> SCNNode {
        let w = 256, h = 64
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: w * h * 4)
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
        for y in 0..<h {
            let v = abs(Float(y) / Float(h - 1) * 2 - 1)           // 0 on the axis, 1 at the plane's edge
            for x in 0..<w {
                let u = Float(x) / Float(w - 1)                       // 0 at the nozzles, 1 at the far end
                let radius = 0.42 + 0.5 * pow(u, 0.7)                 // the plume widens as it expands
                let r = v / radius
                if r >= 1 { continue }
                let across = pow(1 - r * r, 1.6)
                let coreW = max(0, 1 - r / max(0.05, 0.55 - 0.5 * u))
                let diamonds = u < 0.45 ? 0.5 + 0.5 * cos(u * 52) : 0
                let fade = (1 - smooth(0.55, 1, u)) * smooth(0, 0.02, u)
                // colour: blue-white core → pale violet → orange tail
                let hot = coreW * (1 - smooth(0.05, 0.5, u)) * (0.75 + 0.25 * Float(diamonds))
                var R = 1.0 * hot + (0.55 + 0.45 * smooth(0.15, 0.6, u)) * (1 - hot)
                var G = 1.0 * hot + (0.55 - 0.15 * smooth(0.15, 0.6, u)) * (1 - hot)
                var B = 1.0 * hot + (0.95 - 0.8 * smooth(0.1, 0.5, u)) * (1 - hot)
                let a = min(1, across * fade * (0.42 + 0.58 * hot) + 0.12 * Float(diamonds) * coreW * fade)
                R *= a; G *= a; B *= a                                  // premultiplied
                let i = ((h - 1 - y) * w + x) * 4
                px[i] = UInt8(min(255, R * 255)); px[i + 1] = UInt8(min(255, G * 255))
                px[i + 2] = UInt8(min(255, B * 255)); px[i + 3] = UInt8(min(255, a * 255))
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        let node = SCNNode()
        for k in 0..<4 {
            let p = SCNPlane(width: CGFloat(length), height: CGFloat(width))
            p.materials = [m]
            let n = SCNNode(geometry: p)
            // plane x → -z (nozzles at the tail, the image's left edge), spun around the plume's axis
            n.simdOrientation = simd_quatf(angle: Float(k) * .pi / 4, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
            n.simdPosition = SIMD3(0, 0, -length / 2)
            n.renderingOrder = 10
            node.addChildNode(n)
        }
        return node
    }

    /// Stainless hull: ring welds every ~1.8 m, slight panel-to-panel tint, brushed streaks around the barrel.
    private func stainless(_ m: SCNMaterial, y0: Float, y1: Float) {
        m.shaderModifiers = [
            .geometry: """
            #pragma varyings
            float3 stPos;
            #pragma body
            out.stPos = _geometry.position.xyz;
            """,
            .surface: """
            float stH(float2 p) { return fract(sin(dot(p, float2(41.7, 289.3))) * 23758.5453); }
            float stN(float2 p) {
              float2 i = floor(p);
              float2 f = fract(p);
              float2 u = f * f * (3.0 - 2.0 * f);
              return mix(mix(stH(i), stH(i + float2(1, 0)), u.x), mix(stH(i + float2(0, 1)), stH(i + float2(1, 1)), u.x), u.y);
            }
            #pragma arguments
            float uY0;
            float uY1;
            #pragma varyings
            float3 stPos;
            #pragma body
            float t = clamp((in.stPos.y - uY0) / (uY1 - uY0), 0.0, 1.0);
            float r = t * 27.0;
            float id = floor(r);
            float f = fract(r);
            float seam = smoothstep(0.0, 0.025, f) * smoothstep(1.0, 0.975, f);
            float ang = atan2(in.stPos.z, in.stPos.x);
            float brush = stN(float2(ang * 90.0, r * 1.5)) * 0.6 + stN(float2(ang * 260.0, r * 4.0)) * 0.4;
            float tint = 0.94 + 0.09 * stH(float2(id, 3.0));
            _surface.diffuse.rgb *= tint * mix(0.6, 1.0, seam) * (0.94 + 0.1 * brush);
            _surface.metalness = 0.95;
            _surface.roughness = 0.17 + 0.16 * brush + 0.3 * (1.0 - seam);
            """,
        ]
        m.setValue(NSNumber(value: y0), forKey: "uY0")
        m.setValue(NSNumber(value: y1), forKey: "uY1")
    }

    /// Studio-style reflection environment so the stainless steel has something to mirror.
    private func studioEnvironment() -> CGImage {
        let w = 512, h = 256
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorsSpace: nil, colors: [
            CGColor(srgbRed: 0.02, green: 0.025, blue: 0.035, alpha: 1),      // below
            CGColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),        // horizon
            CGColor(srgbRed: 0.42, green: 0.45, blue: 0.5, alpha: 1),         // sky
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        // soft boxes: the sun side and a long top strip
        for (x, y, bw, bh, k) in [(90, 175, 120, 50, 0.95), (330, 205, 160, 22, 0.7), (420, 120, 40, 40, 0.5)] as [(Int, Int, Int, Int, CGFloat)] {
            ctx.setFillColor(CGColor(srgbRed: k, green: k, blue: k * 0.97, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: bw, height: bh))
        }
        return ctx.makeImage()!
    }

    /// A camera-facing additive glow (the Raptors).
    private func glow(inner: NSColor, outer: NSColor, size: CGFloat) -> SCNNode {
        let px = 64
        let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
            NSGradient(colorsAndLocations: (inner, 0), (inner.withAlphaComponent(0.8), 0.12), (outer, 0.35), (outer.withAlphaComponent(0), 1))?
                .draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
        let p = SCNPlane(width: size, height: size)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = img
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        p.materials = [m]
        let n = SCNNode(geometry: p)
        n.constraints = [SCNBillboardConstraint()]
        n.renderingOrder = 10
        return n
    }

    // MARK: oxidation (Starships)

    private func oxidise(_ m: SCNMaterial, y0: Float, y1: Float) {
        m.shaderModifiers = [
            .geometry: """
            #pragma varyings
            float3 oxPos;
            float4 vcol;
            #pragma body
            out.oxPos = _geometry.position.xyz;
            out.vcol = _geometry.color;
            """,
            .surface: Self.oxSurface,
        ]
        m.setValue(NSNumber(value: max(0, min(1, cfg.oxidation))), forKey: "uOx")
        m.setValue(NSNumber(value: y0), forKey: "uY0")
        m.setValue(NSNumber(value: y1), forKey: "uY1")
    }

    /// Frosty white-blue toward the nose, scorched dark tiles in the middle, rust-orange toward the rear, with streaks
    /// swept back from the windward centre line — the same recipe as the web version's GLSL.
    static let oxSurface = """
    float oxH(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    float oxN(float2 p) {
      float2 i = floor(p);
      float2 f = fract(p);
      float2 u = f * f * (3.0 - 2.0 * f);
      return mix(mix(oxH(i), oxH(i + float2(1, 0)), u.x), mix(oxH(i + float2(0, 1)), oxH(i + float2(1, 1)), u.x), u.y);
    }
    float oxF(float2 p) { float v = 0.0; float a = 0.5; for (int k = 0; k < 4; k++) { v += a * oxN(p); p *= 2.03; a *= 0.5; } return v; }

    #pragma arguments
    float uOx;
    float uY0;
    float uY1;
    #pragma varyings
    float3 oxPos;
    float4 vcol;
    #pragma body
    {
      float3 P = in.oxPos;
      float th = atan2(P.x, P.z);
      float at = abs(th);
      float yn = clamp((P.y - uY0) / (uY1 - uY0), 0.0, 1.0);
      float side = 1.0 - smoothstep(0.6, 1.5, at);
      float sweep = mix(0.9, 1.7, smoothstep(0.5, 0.9, yn));
      float u = at + sweep * yn;
      float wob = 0.06 * (oxN(float2(yn * 6.0, at * 4.0)) - 0.5);
      float streak = oxF(float2((u + wob) * 9.0, yn * 1.2));
      float thin = oxN(float2((u + wob) * 95.0, yn * 1.8)) * 0.7 + oxN(float2((u + wob) * 36.0, yn * 0.9)) * 0.3;
      float fine = oxN(float2(th * 70.0, yn * 6.0));
      float on = step(0.001, uOx);
      float rearW = 1.0 - smoothstep(0.38, 0.6, yn);
      float midW = smoothstep(0.38, 0.58, yn) * (1.0 - smoothstep(0.64, 0.78, yn));
      float frontW = smoothstep(0.62, 0.8, yn) * (1.0 - smoothstep(0.95, 1.0, yn));
      float m = side * (0.45 + 0.75 * streak) + 0.16 * (fine - 0.5);
      float cover = clamp((m - (1.0 - 1.15 * uOx)) * 2.6, 0.0, 1.0) * on;
      float patchy = smoothstep(0.32, 0.62, streak * 0.75 + thin * 0.35 + fine * 0.15);
      float keep = smoothstep(0.64, 0.82, oxN(float2(th * 24.0, yn * 9.0))) * (1.0 - 0.6 * uOx);
      float rustK = rearW * cover * mix(patchy, 1.0, smoothstep(0.55, 1.0, uOx) * 0.75) * (1.0 - keep);
      float glow = clamp(streak * 1.2 + thin * 0.4 - 0.3, 0.0, 1.0);
      float3 rust = mix(float3(0.30, 0.06, 0.012), float3(0.98, 0.42, 0.08), glow);
      rust = mix(rust, float3(0.10, 0.04, 0.02), smoothstep(0.8, 0.97, 1.0 - thin) * 0.5);
      float tongue = midW * side * on * smoothstep(0.62, 0.8, thin) * smoothstep(0.35, 0.8, uOx) * 0.8;
      rustK = max(rustK, tongue);
      float scorch = midW * side * uOx * (0.5 + 0.5 * streak);
      float3 c = _surface.diffuse.rgb * in.vcol.rgb;   // vertex colours: black tiles
      c = mix(c, float3(0.05, 0.06, 0.08), scorch * 0.6);
      float frostK = frontW * side * on * smoothstep(1.0 - 0.95 * uOx, 1.25 - 0.95 * uOx, 0.35 + 0.8 * streak + 0.25 * (thin - 0.5));
      float3 frost = mix(float3(0.36, 0.45, 0.58), float3(0.88, 0.91, 0.95), clamp(thin * 1.3 - 0.15, 0.0, 1.0));
      c = mix(c, rust, rustK);
      c = mix(c, frost, frostK);
      float oxK = max(rustK, frostK * 0.6);
      float fleck = step(0.993 - 0.02 * uOx, oxH(floor(float2(th * 90.0, yn * 260.0)))) * on * side * (rearW + 0.4 * midW) * smoothstep(0.1, 0.5, uOx);
      c = mix(c, float3(0.9, 0.9, 0.88), fleck);
      _surface.diffuse.rgb = c;
      _surface.roughness = mix(_surface.roughness, 0.5, oxK);
      _surface.metalness = mix(_surface.metalness, 0.22, oxK);
    }
    """

    // MARK: flight

    private func viewHalf(_ z: Float) -> (w: Float, h: Float) {
        let h = tan(fov * .pi / 360) * (52 - z)
        return (h * aspect, h)
    }

    private func spawn(_ c: Craft, initial: Bool) {
        c.z = -40 + .random(in: 0...45)
        let (w, h) = viewHalf(c.z)
        c.speed = (6 + .random(in: 0...4)) * Float(cfg.speed)
        let mY: Float = kind == .starlink ? 17 : kind == .starships ? 10 : 6
        let mX: Float = kind == .starlink ? 19 : kind == .starships ? 13 : 8
        if initial {
            c.x = .random(in: -1...1) * w * 1.1
            c.y = .random(in: -1...1) * h * 1.1
        } else if Float.random(in: 0...1) < w / (w + h) {
            c.x = (.random(in: 0...2) - 0.6) * w
            c.y = h + mY
        } else {
            c.x = w + mX
            c.y = (.random(in: 0...2) - 0.6) * h
        }
        c.phase = .random(in: 0...(2 * .pi))
        c.dep = initial ? .random(in: 0...9) : 0      // new arrivals come in stowed
        c.depStarted = initial
        c.man = nil
        c.kx = 0; c.ky = 0; c.kz = 0; c.wob = 0
        c.next = clock + 2 + .random(in: 0...9)
        c.gen += 1
    }

    private func ease(_ x: Double) -> Double { x < 0 ? 0 : x > 1 ? 1 : x * x * (3 - 2 * x) }

    /// Offset, extra roll and pitch from the craft's current stunt (barrel roll, veer, climb/dive).
    private func stunt(_ c: Craft, _ t: TimeInterval) -> (off: SIMD3<Float>, roll: Float, pitch: Float)? {
        if c.man == nil, t >= c.next, !cfg.stunts { c.next = t + 5; return nil }
        if c.man == nil, t >= c.next {
            let r = Double.random(in: 0...1)
            let dirn: Float = Bool.random() ? -1 : 1
            if r < 0.3 {
                c.man = Stunt(type: .alt, t0: t, dur: 3 + .random(in: 0...2.5), dirn: dirn, amp: 1.2 + .random(in: 0...2.2)); return nil
            }
            c.man = r < 0.55
                ? Stunt(type: .roll, t0: t, dur: 1.5 + .random(in: 0...0.8), dirn: dirn, amp: 0.9 + .random(in: 0...0.6))
                : Stunt(type: .veer, t0: t, dur: 2.6 + .random(in: 0...1.6), dirn: dirn, amp: 2.5 + .random(in: 0...3))
        }
        guard let m = c.man else { return nil }
        let u = (t - m.t0) / m.dur
        if u >= 1 { c.man = nil; c.next = t + 4 + .random(in: 0...12); return nil }
        switch m.type {
        case .alt:
            let s = Float(sin(u * .pi)), vy = Float(cos(u * .pi) * sin(u * .pi) * 2)
            return (SIMD3(0, s * s * m.amp * m.dirn, 0), 0, vy * 0.22 * m.dirn * min(1, m.amp / 2))
        case .roll:
            let a = Float(ease(u)) * 2 * .pi * m.dirn
            return (perp * (sin(a) * m.amp * m.dirn) + SIMD3(0, 0, (1 - cos(a)) * m.amp), a, 0)
        case .veer:
            let s = Float(sin(u * .pi)), vel = Float(cos(u * .pi))
            return (lat * (s * s * m.amp * m.dirn), -vel * s * 0.55 * m.dirn, 0)
        }
    }

    /// three.js Object3D.lookAt for a non-camera: +z toward the target, up = +y.
    private func lookRotation(_ d: SIMD3<Float>) -> simd_quatf {
        let z = simd_normalize(d)
        var x = simd_cross(SIMD3<Float>(0, 1, 0), z)
        if simd_length(x) < 1e-5 { x = SIMD3(1, 0, 0) }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return simd_quatf(simd_float3x3(columns: (x, y, z)))
    }

    private let radius: [Kind: Float] = [.starlink: 3.2, .starships: 2.8, .cars: 1.7]
    private var lastHit: [Int: TimeInterval] = [:]

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        step(to: time)
    }

    /// Advances the flock to `time` (seconds, any clock).
    func step(to time: TimeInterval) {
        defer { lastTime = time }
        guard let last = lastTime, !paused else { return }
        let dt = Float(max(0, min(0.05, time - last)))
        clock += Double(dt)
        let t = clock
        let damp = exp(-2.2 * dt)
        let marginX: Float = kind == .starlink ? 22 : kind == .starships ? 15 : 10
        let marginY: Float = kind == .starlink ? 20 : kind == .starships ? 12 : 8
        let yRot = simd_quatf(angle: 0.45, axis: SIMD3(0, 1, 0))
        for c in craft {
            // a deploying Starlink drifts at half speed until its arrays are out and flapping
            let pace: Float = c.deploys ? 0.5 + 0.5 * Float(ease(Double((c.dep - 7.8) / 1.5))) : 1
            c.x += c.d.x * c.speed * pace * dt + c.kx * dt
            c.y += c.d.y * c.speed * pace * dt + c.ky * dt
            c.z = max(-45, min(closeupZ ?? 8, c.z + c.kz * dt))
            c.kx *= damp; c.ky *= damp; c.kz *= damp
            c.wob *= exp(-1.6 * dt)
            let (w, h) = viewHalf(c.z)
            if c.lane >= 0 {
                if simd_dot(SIMD2(c.x, c.y), SIMD2(c.d.x, c.d.y)) > laneLength(lanes[c.lane]) { relane(c) }
            } else if c.x < -w - marginX || c.y < -h - marginY { spawn(c, initial: false) }
            let tf = Float(t)
            let bob = sin(tf * 1.3 + c.phase) * 0.35 + sin(tf * 0.23 + c.phase * 2.7) * 0.9
            let stowed = c.deploys && c.dep < 7.8
            if stowed { c.man = nil; c.next = max(c.next, t + 2) }      // no stunts until the arrays are out
            let st = stowed ? nil : stunt(c, t)
            var pos = SIMD3(c.x, c.y + bob, c.z) + (st?.off ?? .zero)
            let wobble = c.wob * sin(tf * 11 + c.phase) * 0.35
            var q = lookRotation(c.d)
            if kind == .starlink { q = q * yRot }
            q = q * simd_quatf(angle: tilt + sin(tf * 0.9 + c.phase) * 0.05 + (st?.roll ?? 0) + wobble, axis: SIMD3(0, 0, 1))
            q = q * simd_quatf(angle: sin(tf * 1.3 + c.phase + 1) * 0.04 - (st?.pitch ?? 0) + wobble * 0.5, axis: SIMD3(1, 0, 0))
            c.spin += dt * Float(max(0.05, cfg.flapSpeed))
            for f in c.fans {
                f.node.simdOrientation = f.q0 * simd_quatf(angle: f.sg * f.rate * c.spin, axis: SIMD3(0, 1, 0))
            }
            if !c.wings.isEmpty {
                let ph0 = c.spin * c.flapRate + c.phase
                // deployment: the linkage swings the stowed stack out from over the bus (link), u unfolds the
                // fan-fold stack straight up, v lays the arrays flat, amp fades the wingbeat in
                var u: Float = 1, v: Float = 1, amp: Float = 1, link: Float = 0
                if c.deploys {
                    if !c.depStarted, abs(c.x) < w * 0.85, abs(c.y) < h * 0.85 { c.depStarted = true }
                    if c.depStarted { c.dep += dt }
                    link = .pi * (1 - Float(ease(Double((c.dep - 0.8) / 1.8))))
                    u = Float(ease(Double((c.dep - 2.8) / 3.2)))
                    v = Float(ease(Double((c.dep - 6.0) / 1.8)))
                    amp = Float(ease(Double((c.dep - 7.8) / 1.5)))
                }
                for l in c.links { l.node.simdOrientation = l.q0 * simd_quatf(angle: l.s * link, axis: SIMD3(0, 0, 1)) }
                // a panel's angle up from flat (world): stowed they alternate d / 180°-d (a level stack), then all 90°, then 0°
                let swing: Float = (Float.pi / 2 - 0.044) * (1 - u)
                func fold(_ i: Int) -> Float {
                    let sign: Float = i % 2 == 0 ? 1 : -1
                    return (Float.pi / 2 - sign * swing) * (1 - v)
                }
                for j in c.wings {
                    let ph = ph0 - Float(j.i) * 0.42
                    let beat = sin(ph) + 0.28 * sin(2 * ph)
                    let flap: Float = j.i == 0 ? 0.05 + 0.34 * beat : 0.012 + (0.95 / Float(j.n)) * beat
                    let base: Float = j.i == 0 ? fold(0) - link : fold(j.i) - fold(j.i - 1)
                    let a: Float = base + amp * flap
                    j.node.simdOrientation = j.q0 * simd_quatf(angle: j.s * a, axis: SIMD3(0, 0, 1))
                }
                pos.y -= 0.35 * cos(ph0) * amp
            }
            if !c.flaps.isEmpty {
                for f in c.flaps {
                    let ph = c.spin * c.flapRate + c.phase - (f.fwd ? 0.6 : 0)
                    let deg = f.fwd ? 42 + 40 * sin(ph) : 50 + 45 * sin(ph)
                    f.node.simdOrientation = f.q0 * simd_quatf(angle: f.s * deg * .pi / 180, axis: SIMD3(0, 1, 0))
                }
                let fl = 0.85 + 0.15 * sin(tf * 37 + c.phase) + 0.08 * sin(tf * 61)
                c.plume?.simdScale = SIMD3(1 + 0.25 * (fl - 0.85), 1 + 0.25 * (fl - 0.85), fl)   // length flickers most
                c.core?.simdScale = SIMD3(repeating: 0.9 + 0.3 * (fl - 0.85))
            }
            c.g.simdPosition = pos
            c.g.simdOrientation = q
        }
        bump(t)
        updateLasers(dt)
    }

    /// Craft that get too close bounce apart (and wobble) instead of flying through each other.
    private func bump(_ t: TimeInterval) {
        let R = radius[kind] ?? 2
        for i in 0..<craft.count {
            for j in (i + 1)..<max(i + 1, craft.count) {
                let a = craft[i], b = craft[j]
                if a.lane >= 0, b.lane >= 0, a.d != b.d { continue }   // crossing passes are at different altitudes
                var n = a.g.simdPosition - b.g.simdPosition
                let d = simd_length(n)
                if d >= 2 * R || d < 1e-4 { continue }
                n /= d
                let push = (2 * R - d) / 2
                a.x += n.x * push; a.y += n.y * push; a.z += n.z * push
                b.x -= n.x * push; b.y -= n.y * push; b.z -= n.z * push
                a.g.simdPosition += n * push
                b.g.simdPosition -= n * push
                let key = i * 64 + j
                if t - (lastHit[key] ?? -10) > 0.8 {
                    lastHit[key] = t
                    let k = 3.2 + Float.random(in: 0...1.5)
                    a.kx += n.x * k; a.ky += n.y * k; a.kz += n.z * k
                    b.kx -= n.x * k; b.ky -= n.y * k; b.kz -= n.z * k
                    a.wob = min(1, a.wob + 0.8); b.wob = min(1, b.wob + 0.8)
                }
            }
        }
    }
}
