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
    func closeup(distance: Float = 30) {
        closeupZ = 52 - distance
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
        var plume: SCNNode?, core: SCNNode?
        var x: Float = 0, y: Float = 0, z: Float = 0, speed: Float = 8, phase: Float = 0
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
                        mat.metalness.contents = 0.5; mat.roughness.contents = 0.38
                        mat.diffuse.contents = NSColor(srgbRed: 0.725, green: 0.745, blue: 0.77, alpha: 1)
                    }
                }
            }
            // the hull's own copy of the tile material (the flaps share the original and stay unburnt)
            for o in [ship] + ship.childNodes where o === ship || o.name?.hasPrefix("ship_") == true {
                guard let g = o.geometry else { continue }
                g.materials = g.materials.map { mat in
                    guard mat.name == "tile", let own = mat.copy() as? SCNMaterial else { return mat }
                    oxidise(own, y0: b.min.y, y1: b.max.y)
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
                let plume = glow(inner: NSColor.white, outer: NSColor(srgbRed: 1, green: 0.59, blue: 0.24, alpha: 0.5), size: 1.9)
                plume.simdPosition = SIMD3(0, 0, tail - 0.4)
                let core = glow(inner: NSColor(srgbRed: 0.86, green: 0.92, blue: 1, alpha: 1), outer: NSColor(srgbRed: 0.47, green: 0.63, blue: 1, alpha: 0.6), size: 0.9)
                core.simdPosition = SIMD3(0, 0, tail - 0.15)
                root.addChildNode(plume); root.addChildNode(core)
                c.plume = plume; c.core = core
                c.flapRate = 5.2 + .random(in: 0...2.2)
                _ = i
                add(c)
            }
        case .starlink:
            let m = try GLB.load(res.appendingPathComponent("Starlink.glb"))
            var want = cfg.liveries.map { $0.uppercased() }.filter { $0 == "V2" || $0 == "V3" }
            if want.isEmpty { want = ["V2", "V3"] }
            var tpl: [String: SCNNode] = [:]
            for name in want {
                guard let sat = m.root.childNode(withName: name, recursively: true) else { continue }
                sat.removeFromParentNode()
                sat.enumerateHierarchy { o, _ in o.geometry?.materials.forEach { $0.isDoubleSided = true } }
                let pivot = SCNNode(); pivot.simdScale = SIMD3(repeating: 0.3); pivot.addChildNode(sat)
                let root = SCNNode(); root.addChildNode(pivot)
                tpl[name] = root
            }
            let have = want.filter { tpl[$0] != nil }
            guard !have.isEmpty else { throw GLBError.badFile("no satellites in Starlink.glb") }
            for i in 0..<n {
                let c = Craft()
                let root = tpl[have[i % have.count]]!.clone()
                c.g.addChildNode(root)
                root.enumerateHierarchy { o, _ in
                    guard let name = o.name, let e = m.extras[name], let w = e["wing"] as? String else { return }
                    c.wings.append((o, o.simdOrientation, w == "R" ? 1 : -1, e["i"] as? Int ?? 0, e["n"] as? Int ?? 1))
                }
                c.flapRate = 3.6 + .random(in: 0...1.6)
                add(c)
            }
        }
    }

    private func add(_ c: Craft) {
        spawn(c, initial: true)
        scene.rootNode.addChildNode(c.g)
        craft.append(c)
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
        c.man = nil
        c.kx = 0; c.ky = 0; c.kz = 0; c.wob = 0
        c.next = clock + 2 + .random(in: 0...9)
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
            c.x += dir.x * c.speed * dt + c.kx * dt
            c.y += dir.y * c.speed * dt + c.ky * dt
            c.z = max(-45, min(closeupZ ?? 8, c.z + c.kz * dt))
            c.kx *= damp; c.ky *= damp; c.kz *= damp
            c.wob *= exp(-1.6 * dt)
            let (w, h) = viewHalf(c.z)
            if c.x < -w - marginX || c.y < -h - marginY { spawn(c, initial: false) }
            let tf = Float(t)
            let bob = sin(tf * 1.3 + c.phase) * 0.35 + sin(tf * 0.23 + c.phase * 2.7) * 0.9
            let st = stunt(c, t)
            var pos = SIMD3(c.x, c.y + bob, c.z) + (st?.off ?? .zero)
            let wobble = c.wob * sin(tf * 11 + c.phase) * 0.35
            var q = lookRotation(dir)
            if kind == .starlink { q = q * yRot }
            q = q * simd_quatf(angle: tilt + sin(tf * 0.9 + c.phase) * 0.05 + (st?.roll ?? 0) + wobble, axis: SIMD3(0, 0, 1))
            q = q * simd_quatf(angle: sin(tf * 1.3 + c.phase + 1) * 0.04 - (st?.pitch ?? 0) + wobble * 0.5, axis: SIMD3(1, 0, 0))
            c.spin += dt * Float(max(0.05, cfg.flapSpeed))
            for f in c.fans {
                f.node.simdOrientation = f.q0 * simd_quatf(angle: f.sg * f.rate * c.spin, axis: SIMD3(0, 1, 0))
            }
            if !c.wings.isEmpty {
                let ph0 = c.spin * c.flapRate + c.phase
                for j in c.wings {
                    let ph = ph0 - Float(j.i) * 0.42
                    let beat = sin(ph) + 0.28 * sin(2 * ph)
                    let a = j.i == 0 ? 0.05 + 0.34 * beat : 0.012 + (0.95 / Float(j.n)) * beat
                    j.node.simdOrientation = j.q0 * simd_quatf(angle: j.s * a, axis: SIMD3(0, 0, 1))
                }
                pos.y -= 0.35 * cos(ph0)
            }
            if !c.flaps.isEmpty {
                for f in c.flaps {
                    let ph = c.spin * c.flapRate + c.phase - (f.fwd ? 0.6 : 0)
                    let deg = f.fwd ? 42 + 40 * sin(ph) : 50 + 45 * sin(ph)
                    f.node.simdOrientation = f.q0 * simd_quatf(angle: f.s * deg * .pi / 180, axis: SIMD3(0, 1, 0))
                }
                let fl = 0.85 + 0.15 * sin(tf * 37 + c.phase) + 0.08 * sin(tf * 61)
                c.plume?.simdScale = SIMD3(repeating: fl)
                c.core?.simdScale = SIMD3(repeating: fl)
            }
            c.g.simdPosition = pos
            c.g.simdOrientation = q
        }
        bump(t)
    }

    /// Craft that get too close bounce apart (and wobble) instead of flying through each other.
    private func bump(_ t: TimeInterval) {
        let R = radius[kind] ?? 2
        for i in 0..<craft.count {
            for j in (i + 1)..<max(i + 1, craft.count) {
                let a = craft[i], b = craft[j]
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
