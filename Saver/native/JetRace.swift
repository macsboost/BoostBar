import AppKit
import CoreText
import JavaScriptCore
import SceneKit
import simd

/// Options for the Jet Racers screen saver (BoostBar ▸ Settings ▸ Screen Saver, or the saver's own Options sheet).
/// The values are the ones Saver/src/jetrace.js understands.
struct JetRaceConfig {
    /// "random" for a fair race, or the number of the racer who always wins: "16", "8" or "3".
    var winner = "random"
    /// "random", or one of the winner's celebrations.
    var celebration = "random"
    var camera = "director"
    var follow = "leader"
    var board = true
    var captions = false

    static let winners: [(id: String, name: String)] = [
        ("random", "Random (a fair race)"), ("16", "Skeeter (#16) always wins"), ("8", "Skison (#8) always wins"), ("3", "Jorge (#3) always wins"),
    ]
    static let celebrations: [(id: String, name: String)] = [
        ("random", "Random"), ("shake", "Stand and shake arms"), ("bow", "Take a bow"), ("bow2", "Formal bow, one arm up"),
        ("backflip", "Backflip off the seat"), ("dab", "Dab"), ("cart", "Shopping cart dance"), ("mower", "Lawn mower"),
        ("sprinkler", "Sprinkler"), ("crane", "Crane kick"),
    ]
    static let cameras: [(id: String, name: String)] = [
        ("director", "Director (cinematic)"), ("chase", "Chase"), ("onboard", "Onboard"), ("side", "Trackside boat"), ("front", "Lead boat"),
        ("heli", "Helicopter"), ("blimp", "Overhead"), ("buoy", "Buoy cam"), ("orbit", "Drone orbit"), ("finish", "Finish line"),
    ]
    static let follows: [(id: String, name: String)] = [
        ("leader", "Race leader"), ("16", "Skeeter (#16)"), ("8", "Skison (#8)"), ("3", "Jorge (#3)"),
    ]

    var json: String {
        let d: [String: Any] = ["winner": winner, "celebration": celebration, "camera": camera, "follow": follow, "board": board, "captions": captions]
        return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// The Jet Racers screen saver, drawn natively with SceneKit (Metal).
///
/// The race itself — course, racing, riders' poses and celebrations, cameras, scoreboard — is Saver/src/jetrace.js,
/// the same script the Windows saver and BoostBar's Preview window run in a web page. Here it runs in JavaScriptCore
/// with no page, and every frame this class copies its results onto SceneKit nodes: where the camera is, how each ski
/// and each rider's joints are turned, the spray and wakes, the start band, the scoreboard.
final class JetRace: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let camera = SCNNode()
    private(set) var error: String?
    var paused = false

    private let ctx: JSContext = JSContext()
    private var jr: JSValue?
    private var outV: JSValue?, pPosV: JSValue?, pAV: JSValue?, pSV: JSValue?, bandV: JSValue?
    private var trailPV: [JSValue] = [], trailUV: [JSValue] = [], jetPV: [JSValue] = []
    private var jetN = 0, jetM = 0
    private var per = 0, np = 0, parts: [String] = []
    private var lastTime: TimeInterval?
    private var clock: Float = 0
    private var viewSize = CGSize(width: 1280, height: 720)
    private var pixelScale: CGFloat = 1

    private struct Racer { let g: SCNNode; let inner: SCNNode; let parts: [SCNNode]; let hips: SCNNode; let trail: SCNNode; let jet: SCNNode }
    private var racers: [Racer] = []
    private let sun = simd_normalize(SIMD3<Float>(-0.42, 0.5, -0.62))
    private let sky = SCNNode(), water = SCNNode(), spray = SCNNode(), band = SCNNode(), course = SCNNode()
    private var waterMat = SCNMaterial(), skyMat = SCNMaterial(), foamMat = SCNMaterial(), sprayMat = SCNMaterial(), jetMat = SCNMaterial()
    private var buoys: [(node: SCNNode, y: Float, ph: Float)] = []
    private var courseSerial: Float = -1, bandSerial: Float = -1, hudSerial: Float = -1
    private let boardNode = SCNNode(), winNode = SCNNode(), capNode = SCNNode(), fadeNode = SCNNode()
    private var boardSize = CGSize.zero, winSize = CGSize.zero, capSize = CGSize.zero
    private var winShown: Float = 0, winWanted = false

    init(cfg: JetRaceConfig, resources: URL) {
        super.init()
        setUpStage()
        do { try start(cfg, resources) } catch { self.error = "\(error)" }
    }

    /// The size the scene is shown at, in points, and how many pixels a point is: the scoreboard and spray are sized from it.
    func setView(size: CGSize, scale: CGFloat) {
        guard size.width > 1, size.height > 1 else { return }
        if size != viewSize || scale != pixelScale { viewSize = size; pixelScale = max(scale, 1); hudSerial = -1 }
    }

    // MARK: JavaScript

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private func start(_ cfg: JetRaceConfig, _ res: URL) throws {
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() ?? "JavaScript error" }
        for name in ["three.min.js", "jetrace.js"] {
            let url = res.appendingPathComponent(name)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { throw Failure(description: "\(name) is missing") }
            ctx.evaluateScript(src, withSourceURL: url)
            if let t = thrown { throw Failure(description: "\(name): \(t)") }
        }
        guard let jr = ctx.objectForKeyedSubscript("JR"), jr.isObject else { throw Failure(description: "the race script did not start") }
        guard let rigs = try? String(contentsOf: res.appendingPathComponent("rigs.json"), encoding: .utf8) else { throw Failure(description: "rigs.json is missing") }
        let info = jr.invokeMethod("init", withArguments: [cfg.json, rigs])?.toString() ?? ""
        if let t = thrown { throw Failure(description: t) }
        guard let data = info.data(using: .utf8), let J = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let errs = (jr.objectForKeyedSubscript("errors")?.toArray() as? [String])?.joined(separator: "; ") ?? ""
            throw Failure(description: errs.isEmpty ? "the race did not start" : errs)
        }
        self.jr = jr
        per = Int(jr.objectForKeyedSubscript("per")?.toInt32() ?? 0)
        np = Int(jr.objectForKeyedSubscript("np")?.toInt32() ?? 0)
        parts = jr.objectForKeyedSubscript("parts")?.toArray() as? [String] ?? []
        outV = jr.objectForKeyedSubscript("out"); pPosV = jr.objectForKeyedSubscript("pPos")
        pAV = jr.objectForKeyedSubscript("pA"); pSV = jr.objectForKeyedSubscript("pS"); bandV = jr.objectForKeyedSubscript("band")
        buildShore(J["shore"] as? [[String: Any]] ?? [], banner: J["banner"] as? String ?? "")
        for (i, r) in (J["racers"] as? [[String: Any]] ?? []).enumerated() {
            guard let ski = r["ski"] as? String, let rider = r["rider"] as? String else { continue }
            try addRacer(ski: res.appendingPathComponent(ski + ".glb"), rider: res.appendingPathComponent(rider + ".glb"))
            if let p = jr.objectForKeyedSubscript("trailP")?.atIndex(i), let u = jr.objectForKeyedSubscript("trailU")?.atIndex(i) { trailPV.append(p); trailUV.append(u) }
            if let j = jr.objectForKeyedSubscript("jetP")?.atIndex(i), !j.isUndefined { jetPV.append(j) }
        }
        jetN = Int(jr.objectForKeyedSubscript("jetN")?.toInt32() ?? 0); jetM = Int(jr.objectForKeyedSubscript("jetM")?.toInt32() ?? 0)
        guard racers.count == 3, trailPV.count == 3, per > 0, np > 0, !parts.isEmpty else { throw Failure(description: "the racers did not load") }
    }

    /// A copy of the numbers in one of the script's Float32Arrays (the first `limit` of them). A copy, because the
    /// array's memory is only promised to stay put until the next call into JavaScriptCore.
    private func floats(_ v: JSValue?, limit: Int = .max) -> [Float]? {
        guard let v, let c = ctx.jsGlobalContextRef, let ref = v.jsValueRef else { return nil }
        var ex: JSValueRef?
        guard let obj = JSValueToObject(c, ref, &ex), ex == nil, let p = JSObjectGetTypedArrayBytesPtr(c, obj, &ex), ex == nil else { return nil }
        let off = JSObjectGetTypedArrayByteOffset(c, obj, &ex), n = min(JSObjectGetTypedArrayLength(c, obj, &ex), limit)
        guard n > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: (p + off).assumingMemoryBound(to: Float.self), count: n))
    }

    /// What the race is doing, as JSON (for checks): phase, finishing order, the celebration, the camera shot.
    var state: String { jr?.invokeMethod("state", withArguments: [])?.toString() ?? "{}" }

    /// Runs the race ahead without drawing it (for checks and recordings).
    func skip(seconds: Double) { _ = jr?.objectForKeyedSubscript("debug")?.invokeMethod("skip", withArguments: [seconds]) }

    // MARK: Stage

    private static func srgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }
    private func pbr(_ hex: Int, roughness: Double, metalness: Double = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = Self.srgb(hex)
        m.roughness.contents = NSNumber(value: roughness)
        m.metalness.contents = NSNumber(value: metalness)
        return m
    }

    /// Value noise shared by the water and the wake foam (the same hash the web version uses).
    private static let noise = """
    float jrH(float2 p) { float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
    float jrN(float2 p) {
      float2 i = floor(p);
      float2 f = fract(p);
      f = f * f * (3.0 - 2.0 * f);
      return mix(mix(jrH(i), jrH(i + float2(1.0, 0.0)), f.x), mix(jrH(i + float2(0.0, 1.0)), jrH(i + float2(1.0, 1.0)), f.x), f.y);
    }
    """
    private static let worldPos = """
    #pragma varyings
    float3 wpos;
    #pragma body
    out.wpos = (scn_node.modelTransform * _geometry.position).xyz;
    """
    /// Extra per-vertex numbers (0…1 each) ride in the vertex colour; these materials replace their colour anyway.
    private static let passData = """
    #pragma varyings
    float3 wpos;
    float3 vdat;
    #pragma body
    out.wpos = (scn_node.modelTransform * _geometry.position).xyz;
    out.vdat = _geometry.color.rgb;
    """

    /// Positions plus one RGBA "colour" of data per vertex, as a triangle mesh.
    private static func dataMesh(positions: [Float], data: [Float], indices: [UInt32], material: SCNMaterial) -> SCNGeometry {
        let n = positions.count / 3
        let g = SCNGeometry(sources: [
            SCNGeometrySource(data: positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
            SCNGeometrySource(data: data.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16),
        ], elements: [SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: 4)])
        g.materials = [material]
        return g
    }

    private static let foamFragment = noise + "\n" + """
    #pragma transparent
    #pragma arguments
    float uT;
    #pragma varyings
    float3 wpos;
    float3 vdat;
    #pragma body
    {
    float2 wp = in.wpos.xz;
    float a = clamp(in.vdat.y, 0.0, 1.0);
    float x = abs(in.vdat.x * 2.0 - 1.0);
    float edge = smoothstep(0.45, 0.85, x) * (1.0 - smoothstep(0.85, 1.0, x));
    float core = (1.0 - smoothstep(0.0, 0.55, x)) * (1.0 - a) * (1.0 - a);
    float2 fw = fwidth(wp);
    float fp = max(fw.x, fw.y);
    float f = mix(jrN(wp * 2.1 + uT * 0.5), 0.5, smoothstep(0.3, 0.75, fp * 2.1)) * 0.6 + mix(jrN(wp * 5.7 - uT * 0.8), 0.5, smoothstep(0.3, 0.75, fp * 5.7)) * 0.4;
    float al = (edge * 0.5 + core) * smoothstep(0.3, 0.72, f + 0.42 * (1.0 - a)) * pow(1.0 - a, 1.4) * in.vdat.z * 0.9;
    _output.color = float4(float3(0.79, 0.89, 0.91) * al, al);
    }
    """
    private static let sprayFragment = """
    #pragma transparent
    #pragma varyings
    float3 wpos;
    float3 vdat;
    #pragma body
    {
    float d = length(in.vdat.xy - float2(0.5, 0.5));
    float al = in.vdat.z * (1.0 - smoothstep(0.12, 0.5, d));
    _output.color = float4(float3(0.85, 0.91, 0.96) * al, al);
    }
    """

    private static func unlit(geometry: String, fragment: String) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        m.isDoubleSided = true
        m.shaderModifiers = [.geometry: geometry, .fragment: fragment]
        return m
    }

    /// A see-through unlit material whose fragment modifier sets the final (premultiplied) colour itself. The modifier
    /// must carry `#pragma transparent`: without it SceneKit draws the material solid, whatever alpha it writes.
    private static func blended(_ fragment: String) -> SCNMaterial {
        let m = unlit(geometry: passData, fragment: fragment)
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        return m
    }

    private func setUpStage() {
        scene.background.contents = NSColor.black
        let cam = SCNCamera()
        cam.fieldOfView = 50
        cam.projectionDirection = .vertical
        cam.zNear = 0.25
        cam.zFar = 16000
        camera.camera = cam
        camera.simdPosition = SIMD3(0, 30, 80)
        scene.rootNode.addChildNode(camera)

        // light: the sky all round, and the sun
        scene.lightingEnvironment.contents = skyEnvironment()
        scene.lightingEnvironment.intensity = 1.25
        let sunLight = SCNLight(); sunLight.type = .directional; sunLight.intensity = 1150
        sunLight.color = NSColor(srgbRed: 1, green: 0.94, blue: 0.86, alpha: 1)
        let sunNode = SCNNode(); sunNode.light = sunLight
        sunNode.simdPosition = sun * 100
        sunNode.simdLook(at: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(sunNode)
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 260
        amb.color = NSColor(srgbRed: 0.86, green: 0.92, blue: 1, alpha: 1)
        let ambNode = SCNNode(); ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        // sky: a dome that follows the camera, with the X1 sim's daytime sky and drifting clouds
        skyMat = Self.unlit(geometry: """
        #pragma varyings
        float3 sdir;
        #pragma body
        out.sdir = _geometry.position.xyz;
        """, fragment: """
        float jsH(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
        float jsN(float2 p) {
          float2 i = floor(p);
          float2 f = fract(p);
          f = f * f * (3.0 - 2.0 * f);
          return mix(mix(jsH(i), jsH(i + float2(1.0, 0.0)), f.x), mix(jsH(i + float2(0.0, 1.0)), jsH(i + float2(1.0, 1.0)), f.x), f.y);
        }
        float jsF(float2 p) { float a = 0.5; float s = 0.0; for (int k = 0; k < 5; k++) { s += a * jsN(p); p *= 2.03; a *= 0.5; } return s; }
        #pragma arguments
        float uT;
        float3 uSun;
        #pragma varyings
        float3 sdir;
        #pragma body
        {
        float3 v = normalize(in.sdir);
        float y = max(v.y, 0.0);
        float s = max(dot(v, uSun), 0.0);
        float3 c = mix(float3(0.80, 0.86, 0.90), float3(0.27, 0.50, 0.74), pow(y, 0.62)) + float3(1.0, 0.9, 0.72) * (pow(s, 600.0) * 6.0 + pow(s, 14.0) * 0.22);
        if (v.y > 0.01) {
          float2 p = v.xz / (v.y + 0.14) * 1.5 + uT * 0.004;
          float f = jsF(p);
          float cl = smoothstep(0.47, 0.74, f) * smoothstep(0.01, 0.2, v.y);
          float3 kd = float3(0.97, 0.96, 0.94) - 0.05 * smoothstep(0.62, 0.85, f);
          c = mix(c, kd, cl * 0.86);
        }
        c = mix(c, float3(0.79, 0.84, 0.88), (1.0 - smoothstep(0.0, 0.09, abs(v.y))) * 0.85);
        c = clamp(c, 0.0, 1.0);
        _output.color = float4(pow(c, float3(4.84)), 1.0);
        }
        """)
        skyMat.cullMode = .front
        skyMat.writesToDepthBuffer = false
        skyMat.readsFromDepthBuffer = false
        skyMat.setValue(NSValue(scnVector3: SCNVector3(sun)), forKey: "uSun")
        let dome = SCNSphere(radius: 9000); dome.segmentCount = 32
        dome.materials = [skyMat]
        sky.geometry = dome
        sky.renderingOrder = -100
        scene.rootNode.addChildNode(sky)

        // water: the X1 sim's water, with the two finer ripple layers the race cameras need close to the surface
        waterMat = Self.unlit(geometry: Self.worldPos, fragment: Self.noise + "\n" + """
        float jrW(float2 p, float t, float4 ow, float2 ow2) {
          return jrN(p * 0.11 + t * 0.09) * ow.x + jrN(p * 0.27 - t * 0.13) * 0.55 * ow.y + jrN(p * 0.73 + t * 0.25) * 0.28 * ow.z
               + jrN(p * 1.9 - t * 0.42) * 0.13 * ow.w + jrN(p * 4.7 + t * 0.8) * 0.06 * ow2.x + jrN(p * 11.3 - t * 1.3) * 0.026 * ow2.y;
        }
        float3 jrFit(float3 v) { float3 a = v * (v + 0.0245786) - 0.000090537; float3 b = v * (0.983729 * v + 0.4329510) + 0.238081; return a / b; }
        float3 jrFilm(float3 c) {
          float3x3 mi = float3x3(float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383), float3(0.04823, 0.01566, 0.83777));
          float3x3 mo = float3x3(float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276), float3(-0.07367, -0.00605, 1.07602));
          c = mi * (c * (0.95 / 0.6));
          c = mo * jrFit(c);
          return clamp(c, 0.0, 1.0);
        }
        #pragma arguments
        float uT;
        float3 uCam;
        float3 uSun;
        #pragma varyings
        float3 wpos;
        #pragma body
        {
        float3 w = in.wpos;
        float3 v = uCam - w;
        float dist = length(v);
        v /= dist;
        float2 q = w.xz;
        float2 fw = fwidth(q);
        float fp = max(fw.x, fw.y);
        float4 ow = float4(1.0) - smoothstep(float4(0.3), float4(0.75), fp * float4(0.11, 0.27, 0.73, 1.9));
        float2 ow2 = float2(1.0) - smoothstep(float2(0.3), float2(0.75), fp * float2(4.7, 11.3));
        float e = max(mix(mix(0.045, 0.28, smoothstep(2.0, 40.0, dist)), 5.0, smoothstep(40.0, 1500.0, dist)), fp * 1.5);
        float d0 = jrW(q, uT, ow, ow2);
        float dx = jrW(q + float2(e, 0.0), uT, ow, ow2) - d0;
        float dz = jrW(q + float2(0.0, e), uT, ow, ow2) - d0;
        float amp = mix(0.9, 0.1, smoothstep(60.0, 1100.0, dist));
        float3 N = normalize(float3(-dx / e * amp, 1.0, -dz / e * amp));
        float F = 0.03 + 0.97 * pow(1.0 - max(dot(v, N), 0.0), 5.0);
        float3 R = reflect(-v, N);
        R.y = abs(R.y);
        float3 sk = mix(float3(0.62, 0.70, 0.76), float3(0.20, 0.40, 0.60), pow(R.y, 0.55));
        float3 c = mix(mix(float3(0.02, 0.19, 0.21), float3(0.012, 0.085, 0.125), clamp(d0 * 0.75, 0.0, 1.0)), sk, F);
        c += float3(1.0, 0.93, 0.8) * pow(max(dot(R, uSun), 0.0), 320.0) * 7.0 * mix(1.0, 0.12, smoothstep(150.0, 1400.0, dist));
        float fog = 1.0 - exp(-pow(dist / 5200.0, 2.0));
        c = mix(c, pow(float3(0.79, 0.84, 0.88), float3(2.2)), fog);
        _output.color = float4(jrFilm(c), 1.0);
        }
        """)
        waterMat.setValue(NSValue(scnVector3: SCNVector3(sun)), forKey: "uSun")
        let half: Float = 13000
        water.geometry = Self.mesh(positions: [SIMD3(-half, 0, -half), SIMD3(-half, 0, half), SIMD3(half, 0, half), SIMD3(half, 0, -half)],
                                   normals: Array(repeating: SIMD3(0, 1, 0), count: 4), indices: [0, 1, 2, 0, 2, 3], material: waterMat)
        water.renderingOrder = -50
        scene.rootNode.addChildNode(water)

        // wakes: a ribbon of foam behind each ski (the ribbons are rebuilt every frame from the script's points)
        foamMat = Self.blended(Self.foamFragment)
        foamMat.readsFromDepthBuffer = false   // flat on the water and drawn straight after it, so nothing can be in front

        // pump jets: a thin stream of water from each steering nozzle to where it lands (rebuilt every frame from the script's rings)
        jetMat.lightingModel = .constant
        jetMat.diffuse.contents = NSColor(srgbRed: 0.93, green: 0.97, blue: 0.98, alpha: 1)
        jetMat.transparency = 0.86
        jetMat.isDoubleSided = true
        jetMat.writesToDepthBuffer = false

        // spray: soft round flecks that face the camera
        sprayMat = Self.blended(Self.sprayFragment)
        spray.renderingOrder = 30
        scene.rootNode.addChildNode(spray)

        band.geometry = nil
        scene.rootNode.addChildNode(band)
        scene.rootNode.addChildNode(course)

        // scoreboard, winner banner, camera caption and the fade between races: flat cards right in front of the lens
        for (n, order) in [(boardNode, 900), (winNode, 901), (capNode, 902), (fadeNode, 950)] {
            let g = SCNPlane(width: 1, height: 1)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = NSColor.black
            m.blendMode = .alpha
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            g.materials = [m]
            n.geometry = g
            n.renderingOrder = order
            n.isHidden = n !== fadeNode
            n.castsShadow = false
            camera.addChildNode(n)
        }
    }

    /// What the skis and riders reflect: blue overhead, bright haze at the horizon, sea below.
    private func skyEnvironment() -> CGImage {
        let w = 256, h = 128
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorsSpace: nil, colors: [
            CGColor(srgbRed: 0.10, green: 0.30, blue: 0.36, alpha: 1),   // straight down: the sea
            CGColor(srgbRed: 0.22, green: 0.47, blue: 0.52, alpha: 1),
            CGColor(srgbRed: 0.88, green: 0.92, blue: 0.95, alpha: 1),   // horizon haze
            CGColor(srgbRed: 0.55, green: 0.72, blue: 0.90, alpha: 1),
            CGColor(srgbRed: 0.33, green: 0.55, blue: 0.82, alpha: 1),   // straight up
        ] as CFArray, locations: [0, 0.46, 0.5, 0.62, 1])!
        c.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return c.makeImage()!
    }

    /// A triangle mesh from plain arrays.
    private static func mesh(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32], material: SCNMaterial) -> SCNGeometry {
        func source(_ a: [SIMD3<Float>], _ sem: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            var flat = [Float](); flat.reserveCapacity(a.count * 3)
            for v in a { flat.append(v.x); flat.append(v.y); flat.append(v.z) }
            let d = flat.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: d, semantic: sem, vectorCount: a.count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let el = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                    primitiveCount: indices.count / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [source(positions, .vertex), source(normals, .normal)], elements: [el])
        g.materials = [material]
        return g
    }

    /// The beach behind the course: sand, hills, palms, tents and the banner, from the script's list.
    private func buildShore(_ list: [[String: Any]], banner: String) {
        let shore = SCNNode()
        let sandPts = [SIMD3<Float>(-2600, -0.5, -150), SIMD3(2600, -0.5, -150), SIMD3(2600, 7, -520), SIMD3(-2600, 7, -520)]
        let sandN = simd_normalize(simd_cross(sandPts[1] - sandPts[0], sandPts[2] - sandPts[0]))
        let sandMat = pbr(0xd8c69a, roughness: 1); sandMat.isDoubleSided = true
        shore.addChildNode(SCNNode(geometry: Self.mesh(positions: sandPts, normals: Array(repeating: sandN, count: 4), indices: [0, 1, 2, 0, 2, 3], material: sandMat)))
        func sphere(_ segments: Int, _ m: SCNMaterial) -> SCNGeometry { let g = SCNSphere(radius: 1); g.segmentCount = segments; g.materials = [m]; return g }
        func post(_ m: SCNMaterial) -> SCNGeometry { let g = SCNCone(topRadius: 0.16, bottomRadius: 0.26, height: 1); g.radialSegmentCount = 6; g.materials = [m]; return g }
        let geo: [String: SCNGeometry] = [
            "hill": sphere(14, pbr(0x2f5a35, roughness: 1)), "leaf": sphere(8, pbr(0x2c6b3a, roughness: 0.9)),
            "trunk": post(pbr(0x6b5238, roughness: 1)), "post": post(pbr(0xdddddd, roughness: 1)), "mast": post(pbr(0x888888, roughness: 1)),
        ]
        var roofs: [Int: SCNGeometry] = [:]
        func f3(_ v: Any?) -> SIMD3<Float>? {
            guard let a = v as? [NSNumber], a.count == 3 else { return nil }
            return SIMD3(a[0].floatValue, a[1].floatValue, a[2].floatValue)
        }
        for o in list {
            guard let k = o["k"] as? String, var p = f3(o["p"]) else { continue }
            let n = SCNNode()
            if k == "roof" {
                let hex = (o["c"] as? NSNumber)?.intValue ?? 0xffffff
                if roofs[hex] == nil {
                    let g = SCNPyramid(width: 4.525, height: 1.6, length: 4.525)   // a square tent roof, 3.2 m from centre to corner
                    g.materials = [pbr(hex, roughness: 0.8)]
                    roofs[hex] = g
                }
                n.geometry = roofs[hex]
                p.y -= 0.8   // the pyramid stands on its base; the script places the roof by its middle
            } else {
                guard let g = geo[k] else { continue }
                n.geometry = g
            }
            n.simdPosition = p
            if let s = f3(o["s"]) { n.simdScale = s }
            if let rz = (o["rz"] as? NSNumber)?.floatValue { n.simdEulerAngles = SIMD3(0, 0, rz) }
            shore.addChildNode(n)
        }
        // the banner
        let W = 1024, H = 152
        if let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.setFillColor(Self.srgb(0x0b0b0c)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
            c.setFillColor(Self.srgb(0xff7a1a)); c.fill(CGRect(x: 0, y: 0, width: W, height: 14)); c.fill(CGRect(x: 0, y: H - 14, width: W, height: 14))
            var size: CGFloat = 84
            var line = Self.line(banner, Self.font("HelveticaNeue-BoldItalic", size), Self.srgb(0xffffff))
            if line.width > CGFloat(W - 40) { size *= CGFloat(W - 40) / line.width; line = Self.line(banner, Self.font("HelveticaNeue-BoldItalic", size), Self.srgb(0xffffff)) }
            c.textPosition = CGPoint(x: (CGFloat(W) - line.width) / 2, y: CGFloat(H) / 2 - size * 0.36)
            CTLineDraw(line.line, c)
            if let img = c.makeImage() {
                let g = SCNPlane(width: 34, height: 5)
                let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = img; m.isDoubleSided = true
                g.materials = [m]
                let n = SCNNode(geometry: g); n.simdPosition = SIMD3(0, 6.4, -168)
                shore.addChildNode(n)
            }
        }
        scene.rootNode.addChildNode(shore)
    }

    private func addRacer(ski: URL, rider: URL) throws {
        let s = try GLB.load(ski), r = try GLB.load(rider)
        guard let seat = s.root.childNode(withName: "SeatMount", recursively: true) else { throw Failure(description: "SeatMount missing in \(ski.lastPathComponent)") }
        seat.addChildNode(r.root)
        let g = SCNNode(), inner = SCNNode()
        inner.addChildNode(s.root); g.addChildNode(inner)
        scene.rootNode.addChildNode(g)
        var nodes: [SCNNode] = []
        for name in parts {
            guard let n = g.childNode(withName: name, recursively: true) else { throw Failure(description: "\(name) missing in the \(ski.lastPathComponent) racer") }
            nodes.append(n)
        }
        guard let hips = g.childNode(withName: "Hips", recursively: true) else { throw Failure(description: "Hips missing") }
        let trail = SCNNode(); trail.renderingOrder = -40
        scene.rootNode.addChildNode(trail)
        let jet = SCNNode(); jet.renderingOrder = 20
        scene.rootNode.addChildNode(jet)
        racers.append(Racer(g: g, inner: inner, parts: nodes, hips: hips, trail: trail, jet: jet))
    }

    // MARK: Course

    private func checkers() -> CGImage? {
        let q = 32, W = 256, H = 128
        guard let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for i in 0..<(W / q) { for j in 0..<(H / q) {
            c.setFillColor(Self.srgb((i + j) % 2 == 1 ? 0x0a0a0a : 0xf6f6f6))
            c.fill(CGRect(x: i * q, y: j * q, width: q, height: q))
        } }
        return c.makeImage()
    }
    private lazy var redBuoy: SCNGeometry = { let g = SCNSphere(radius: 0.3048); g.segmentCount = 24; g.materials = [pbr(0xcc0408, roughness: 0.55)]; return g }()
    private lazy var greenBuoy: SCNGeometry = { let g = SCNSphere(radius: 0.3048); g.segmentCount = 24; g.materials = [pbr(0x008a2a, roughness: 0.55)]; return g }()
    private lazy var finishBuoy: SCNGeometry = {
        let g = SCNSphere(radius: 0.42); g.segmentCount = 28
        let m = pbr(0xffffff, roughness: 0.4)
        if let img = checkers() { m.diffuse.contents = img }
        g.materials = [m]
        return g
    }()
    private lazy var bandMat: SCNMaterial = pbr(0xf2d21c, roughness: 0.6)

    /// A new race: its buoys (red = turn left, green = turn right), the start gate's two poles and the finish buoys.
    private func buildCourse() {
        guard let s = jr?.invokeMethod("course", withArguments: [])?.toString(), let d = s.data(using: .utf8),
              let J = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        course.childNodes.forEach { $0.removeFromParentNode() }
        buoys = []
        func num(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
        for b in J["buoys"] as? [[String: Any]] ?? [] {
            let n = SCNNode(geometry: (b["left"] as? Bool ?? false) ? redBuoy : greenBuoy)
            n.simdPosition = SIMD3(num(b["x"]), 0.15, num(b["z"]))
            course.addChildNode(n)
            buoys.append((n, 0.15, Float.random(in: 0..<(2 * .pi))))
        }
        let pole = SCNCylinder(radius: 0.07, height: 3); pole.radialSegmentCount = 12; pole.materials = [pbr(0xf4f4f4, roughness: 0.5)]
        let cap = SCNCylinder(radius: 0.1, height: 0.3); cap.radialSegmentCount = 12; cap.materials = [pbr(0xff7a1a, roughness: 0.5)]
        for p in J["poles"] as? [[NSNumber]] ?? [] where p.count == 2 {
            let a = SCNNode(geometry: pole); a.simdPosition = SIMD3(p[0].floatValue, 0.35, p[1].floatValue); course.addChildNode(a)
            let b = SCNNode(geometry: cap); b.simdPosition = SIMD3(p[0].floatValue, 1.85, p[1].floatValue); course.addChildNode(b)
        }
        for p in J["finish"] as? [[NSNumber]] ?? [] where p.count == 2 {
            let n = SCNNode(geometry: finishBuoy)
            n.simdPosition = SIMD3(p[0].floatValue, 0.2, p[1].floatValue)
            course.addChildNode(n)
            buoys.append((n, 0.2, Float.random(in: 0..<(2 * .pi))))
        }
    }

    /// The yellow rubber start band, as a thin tube through the script's points.
    private func buildBand() {
        guard let p = floats(bandV), p.count >= 6 else { return }
        let n = p.count / 3, sides = 6
        let r: Float = 0.035
        var pts = [SIMD3<Float>](); pts.reserveCapacity(n)
        for i in 0..<n { pts.append(SIMD3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])) }
        var pos = [SIMD3<Float>](), nor = [SIMD3<Float>](), idx = [UInt32]()
        for i in 0..<n {
            var t = pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]
            t = simd_length(t) > 1e-6 ? simd_normalize(t) : SIMD3(1, 0, 0)
            var a = simd_cross(t, abs(t.y) > 0.95 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0))
            a = simd_normalize(a)
            let b = simd_cross(t, a)
            for k in 0..<sides {
                let ang = Float(k) / Float(sides) * 2 * .pi
                let d = a * cos(ang) + b * sin(ang)
                pos.append(pts[i] + d * r); nor.append(d)
            }
        }
        for i in 0..<(n - 1) { for k in 0..<sides {
            let a = UInt32(i * sides + k), b = UInt32(i * sides + (k + 1) % sides), c = a + UInt32(sides), d = b + UInt32(sides)
            idx += [a, b, c, b, d, c]
        } }
        bandMat.isDoubleSided = true
        band.geometry = Self.mesh(positions: pos, normals: nor, indices: idx, material: bandMat)
    }

    // MARK: Frame

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        step(to: time)
    }

    func step(to time: TimeInterval) {
        let dt = lastTime.map { min(max(time - $0, 0), 0.05) } ?? 0
        lastTime = time
        guard !paused, error == nil, let jr else { return }
        _ = jr.invokeMethod("tick", withArguments: [dt])
        guard let o = floats(outV), o.count >= 16 + per * racers.count else { return }
        clock = o[13]

        let camPos = SIMD3<Float>(o[0], o[1], o[2]), camQ = simd_quatf(ix: o[3], iy: o[4], iz: o[5], r: o[6])
        camera.simdPosition = camPos
        camera.simdOrientation = camQ
        let fov = o[7], near = o[8]
        if let c = camera.camera {
            c.fieldOfView = CGFloat(fov)
            c.zNear = Double(near)
        }
        sky.simdPosition = camPos
        let t = NSNumber(value: clock)
        skyMat.setValue(t, forKey: "uT"); waterMat.setValue(t, forKey: "uT"); foamMat.setValue(t, forKey: "uT")
        waterMat.setValue(NSValue(scnVector3: SCNVector3(camPos)), forKey: "uCam")

        if o[10] != courseSerial { courseSerial = o[10]; buildCourse() }
        if o[11] != bandSerial { bandSerial = o[11]; buildBand() }
        for b in buoys {
            b.node.simdPosition.y = b.y + 0.035 * sin(clock * 1.9 + b.ph)
            b.node.simdEulerAngles = SIMD3(0, 0, 0.06 * sin(clock * 1.3 + b.ph))
        }

        var tails: [Int] = []
        for (i, r) in racers.enumerated() {
            var k = 16 + i * per
            r.g.simdPosition = SIMD3(o[k], o[k + 1], o[k + 2])
            r.g.simdOrientation = simd_quatf(ix: o[k + 3], iy: o[k + 4], iz: o[k + 5], r: o[k + 6])
            r.inner.simdOrientation = simd_quatf(ix: o[k + 7], iy: o[k + 8], iz: o[k + 9], r: o[k + 10])
            k += 11
            for n in r.parts { n.simdOrientation = simd_quatf(ix: o[k], iy: o[k + 1], iz: o[k + 2], r: o[k + 3]); k += 4 }
            r.hips.simdPosition = SIMD3(o[k], o[k + 1], o[k + 2])
            tails.append(Int(o[k + 3]))
        }
        let fade = o[9]
        let hud = o[12]
        for (i, r) in racers.enumerated() { buildTrail(r, count: tails[i], p: floats(trailPV[i], limit: tails[i] * 6), u: floats(trailUV[i], limit: tails[i] * 6)) }
        let jets = Int(o[14])
        for (i, r) in racers.enumerated() { buildJet(r, on: jets & (1 << i) != 0, p: i < jetPV.count ? floats(jetPV[i], limit: jetN * jetM * 3) : nil) }
        buildSpray(camPos: camPos, camQ: camQ, fov: fov)
        if hud != hudSerial { hudSerial = hud; drawHud() }
        layoutHud(fov: fov, near: near, fade: fade, dt: Float(dt))
    }

    private func buildTrail(_ r: Racer, count: Int, p: [Float]?, u: [Float]?) {
        guard let p, let u, count >= 2, p.count >= count * 6, u.count >= count * 6 else { r.trail.geometry = nil; return }
        var data = [Float](); data.reserveCapacity(count * 8)   // per vertex: which edge (0 or 1), age 0…1, how hard the ski was running
        for i in 0..<(count * 2) { data.append(u[i * 3] * 0.5 + 0.5); data.append(u[i * 3 + 1]); data.append(u[i * 3 + 2]); data.append(1) }
        var idx = [UInt32](); idx.reserveCapacity((count - 1) * 6)
        for i in 0..<UInt32(count - 1) { idx += [i * 2, i * 2 + 1, i * 2 + 2, i * 2 + 1, i * 2 + 3, i * 2 + 2] }
        r.trail.geometry = Self.dataMesh(positions: Array(p[0..<(count * 6)]), data: data, indices: idx, material: foamMat)
    }

    /// The pump jet: a tube through the script's rings of points (jetN rings of jetM points, nozzle first).
    private func buildJet(_ r: Racer, on: Bool, p: [Float]?) {
        let count = jetN * jetM
        guard on, let p, jetN >= 2, jetM >= 3, p.count >= count * 3 else { r.jet.geometry = nil; return }
        var idx = [UInt32](); idx.reserveCapacity((jetN - 1) * jetM * 6)
        let m = UInt32(jetM)
        for i in 0..<UInt32(jetN - 1) {
            for j in 0..<m {
                let a = i * m + j, b = i * m + (j + 1) % m
                idx += [a, b, a + m, b, b + m, a + m]
            }
        }
        r.jet.geometry = Self.dataMesh(positions: Array(p[0..<(count * 3)]), data: [Float](repeating: 1, count: count * 4), indices: idx, material: jetMat)
    }

    private func buildSpray(camPos: SIMD3<Float>, camQ: simd_quatf, fov: Float) {
        guard let pos = floats(pPosV), let alpha = floats(pAV), let size = floats(pSV), pos.count >= np * 3, alpha.count >= np, size.count >= np else { spray.geometry = nil; return }
        let right = camQ.act(SIMD3<Float>(1, 0, 0)), up = camQ.act(SIMD3<Float>(0, 1, 0)), fwd = camQ.act(SIMD3<Float>(0, 0, -1))
        let sc = Float(viewSize.height * min(pixelScale, 1.75)) / (2 * tan(fov * .pi / 360))   // pixels per metre, one metre away
        var v = [Float](), d = [Float](), idx = [UInt32]()
        v.reserveCapacity(4096 * 3); d.reserveCapacity(4096 * 4); idx.reserveCapacity(4096 * 2)
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        var n: UInt32 = 0
        for i in 0..<np where alpha[i] > 0.004 {
            let p = SIMD3<Float>(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
            let depth = simd_dot(p - camPos, fwd)
            guard depth > 0.3 else { continue }
            let px = size[i] * sc / depth                      // how many pixels across the fleck would be
            let shown = min(max(px, 1.6), 48)
            let a = alpha[i] * smooth(1.2, 4.5, depth) * min(max(px * 0.6, 0), 1)
            guard a > 0.004 else { continue }
            let half = shown * depth / sc * 0.5
            for (cx, cy) in corners {
                let q = p + right * (cx * half) + up * (cy * half)
                v.append(q.x); v.append(q.y); v.append(q.z)
                d.append(cx * 0.5 + 0.5); d.append(cy * 0.5 + 0.5); d.append(a); d.append(1)
            }
            idx += [n, n + 1, n + 2, n, n + 2, n + 3]
            n += 4
        }
        guard n > 0 else { spray.geometry = nil; return }
        spray.geometry = Self.dataMesh(positions: v, data: d, indices: idx, material: sprayMat)
    }

    private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }

    // MARK: Scoreboard

    private static func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
    private static func line(_ s: String, _ font: CTFont, _ color: CGColor, kern: CGFloat = 0) -> (line: CTLine, width: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        return (l, CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) - (s.isEmpty ? 0 : kern))
    }
    private static func hex(_ s: String?) -> CGColor {
        guard let s, s.hasPrefix("#"), let v = Int(s.dropFirst(), radix: 16) else { return srgb(0xffffff) }
        return srgb(v)
    }

    /// A card drawn top-down in points, at the screen's pixel density.
    private func card(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
        let k = max(1, min(pixelScale, 3))
        let W = Int((size.width * k).rounded(.up)), H = Int((size.height * k).rounded(.up))
        guard W > 0, H > 0, let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: k, y: k)
        c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)      // y runs down the card, like the web page's layout
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        draw(c)
        return c.makeImage()
    }
    private func text(_ c: CGContext, _ l: (line: CTLine, width: CGFloat), x: CGFloat, baseline: CGFloat) {
        c.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(l.line, c)
    }
    private func fill(_ c: CGContext, _ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        c.setFillColor(color)
        if radius > 0 { c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); c.fillPath() } else { c.fill(r) }
    }
    private func show(_ node: SCNNode, _ img: CGImage?) {
        guard let img else { node.isHidden = true; return }
        node.geometry?.firstMaterial?.diffuse.contents = img
        node.isHidden = false
    }

    /// How much bigger than the web page's fixed sizes to draw, so the board stays readable on a big display.
    private var hudScale: CGFloat { max(1, viewSize.height / 900) }

    /// Redraws the leaderboard, the winner banner and the camera caption from the script's scoreboard.
    private func drawHud() {
        guard let s = jr?.invokeMethod("hud", withArguments: [])?.toString(), let d = s.data(using: .utf8),
              let H = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        let z = hudScale
        let orange = Self.srgb(0xff7a1a), ink = Self.srgb(0x0b0b0c), white = Self.srgb(0xffffff)
        let bold = "HelveticaNeue-Bold", heavyItalic = "HelveticaNeue-BoldItalic", medium = "HelveticaNeue-Medium"

        let rows = H["rows"] as? [[String: Any]] ?? []
        if H["board"] as? Bool ?? true, !rows.isEmpty {
            let head: CGFloat = 30 * z, rowH: CGFloat = 32 * z
            var w: CGFloat = 214 * z   // wider if a row needs it: number, chip, name, holeshot badge, gap
            for r in rows {
                let name = Self.line(r["name"] as? String ?? "", Self.font(bold, 11 * z), white, kern: 1.1 * z)
                let gap = Self.line(r["gap"] as? String ?? "", Self.font(medium, 12 * z), white)
                let badge: CGFloat = (r["hs"] as? Bool ?? false) ? 30 * z : 0
                w = max(w, 78 * z + name.width + badge + 12 * z + gap.width + 12 * z)
            }
            boardSize = CGSize(width: w, height: head + rowH * CGFloat(rows.count))
            show(boardNode, card(boardSize) { c in
                c.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: self.boardSize), cornerWidth: 8 * z, cornerHeight: 8 * z, transform: nil)); c.clip()
                self.fill(c, CGRect(origin: .zero, size: self.boardSize), Self.srgb(0x1b2836, 0.78))
                self.fill(c, CGRect(x: 0, y: 0, width: w, height: head), orange)
                let hf = Self.font(bold, 12 * z)
                self.text(c, Self.line(H["lap"] as? String ?? "", hf, ink, kern: 1 * z), x: 12 * z, baseline: 20 * z)
                let clock = Self.line(H["clock"] as? String ?? "", hf, ink, kern: 1 * z)
                self.text(c, clock, x: w - 12 * z - clock.width, baseline: 20 * z)
                for (i, r) in rows.enumerated() {
                    let y = head + rowH * CGFloat(i), base = y + 21 * z
                    if i > 0 { self.fill(c, CGRect(x: 0, y: y, width: w, height: max(1, z)), Self.srgb(0xffffff, 0.07)) }
                    self.text(c, Self.line("\(i + 1)", Self.font(bold, 13 * z), Self.srgb(0xffffff, 0.85)), x: 12 * z, baseline: base)
                    let chip = r["chip"] as? [String] ?? []
                    let num = Self.line("\((r["id"] as? NSNumber)?.intValue ?? 0)", Self.font(heavyItalic, 13 * z), Self.hex(chip.count > 1 ? chip[1] : nil))
                    let cw = max(36 * z, num.width + 12 * z), chipR = CGRect(x: 33 * z, y: y + 6 * z, width: cw, height: 20 * z)
                    self.fill(c, chipR.insetBy(dx: -z, dy: -z), Self.srgb(0xffffff, 0.25), radius: 5 * z)
                    self.fill(c, chipR, Self.hex(chip.first), radius: 4 * z)
                    self.text(c, num, x: chipR.midX - num.width / 2, baseline: base - 0.5 * z)
                    let name = Self.line(r["name"] as? String ?? "", Self.font(bold, 11 * z), Self.srgb(0xffffff, 0.9), kern: 1.1 * z)
                    let nx = chipR.maxX + 9 * z
                    self.text(c, name, x: nx, baseline: base - 0.5 * z)
                    if r["hs"] as? Bool ?? false {
                        let hs = Self.line("HS", Self.font(bold, 9 * z), ink, kern: 0.4 * z)
                        let br = CGRect(x: nx + name.width + 7 * z, y: y + 9.5 * z, width: hs.width + 8 * z, height: 13 * z)
                        self.fill(c, br, orange, radius: 3 * z)
                        self.text(c, hs, x: br.minX + 4 * z, baseline: br.maxY - 3.2 * z)
                    }
                    let gap = Self.line(r["gap"] as? String ?? "", Self.font(medium, 12 * z), white)
                    self.text(c, gap, x: w - 12 * z - gap.width, baseline: base)
                }
            })
        } else { boardNode.isHidden = true }

        if let win = H["win"] as? [String: Any] {
            let chip = win["chip"] as? [String] ?? []
            let title = Self.line("\(win["name"] as? String ?? "") WINS", Self.font(heavyItalic, 34 * z), white, kern: 1.4 * z)
            let num = Self.line("\((win["id"] as? NSNumber)?.intValue ?? 0)", Self.font(heavyItalic, 30 * z), Self.hex(chip.count > 1 ? chip[1] : nil))
            let sub = Self.line(win["sub"] as? String ?? "", Self.font(medium, 12 * z), Self.srgb(0xffffff, 0.75), kern: 1.7 * z)
            let chipW = max(52 * z, num.width + 24 * z)
            let inner: CGFloat = max(chipW + 14 * z + title.width, sub.width)
            let w: CGFloat = 52 * z + inner, h: CGFloat = 90 * z
            winSize = CGSize(width: w, height: h)
            show(winNode, card(winSize) { c in
                c.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: self.winSize), cornerWidth: 6 * z, cornerHeight: 6 * z, transform: nil)); c.clip()
                self.fill(c, CGRect(origin: .zero, size: self.winSize), Self.srgb(0x10202c, 0.82))
                self.fill(c, CGRect(x: 0, y: 0, width: 6 * z, height: h), orange)
                let chipR = CGRect(x: 26 * z, y: 15 * z, width: chipW, height: 42 * z)
                self.fill(c, chipR.insetBy(dx: -z, dy: -z), Self.srgb(0xffffff, 0.25), radius: 5 * z)
                self.fill(c, chipR, Self.hex(chip.first), radius: 4 * z)
                self.text(c, num, x: chipR.midX - num.width / 2, baseline: chipR.maxY - 10.5 * z)
                self.text(c, title, x: chipR.maxX + 14 * z, baseline: 48 * z)
                self.text(c, sub, x: 26 * z, baseline: 74 * z)
            })
            winWanted = true
        } else { winWanted = false }

        let cap = H["cap"] as? String ?? ""
        if H["capOn"] as? Bool ?? false, !cap.isEmpty {
            let l = Self.line(cap, Self.font(bold, 11 * z), Self.srgb(0xffffff, 0.8), kern: 2.4 * z)
            capSize = CGSize(width: l.width + 8 * z, height: 18 * z)
            show(capNode, card(capSize) { c in
                c.setShadow(offset: CGSize(width: 0, height: -1 * z), blur: 3 * z, color: Self.srgb(0x000000, 0.9))
                self.text(c, l, x: 3 * z, baseline: 13 * z)
            })
        } else { capNode.isHidden = true }
    }

    /// Puts the cards where the web page has them: board top left, caption bottom left, winner bottom centre.
    private func layoutHud(fov: Float, near: Float, fade: Float, dt: Float) {
        let d = near * 2 + 0.05                                   // just beyond the near plane, in front of everything
        let halfH = d * tan(fov * .pi / 360), k = 2 * halfH / Float(viewSize.height)   // metres per point
        let W = Float(viewSize.width), H = Float(viewSize.height), z = Float(hudScale)
        func place(_ n: SCNNode, _ size: CGSize, left: Float, top: Float, alpha: Float = 1) {
            let w = Float(size.width), h = Float(size.height)
            n.simdPosition = SIMD3((left + w / 2 - W / 2) * k, (H / 2 - top - h / 2) * k, -d)
            n.simdScale = SIMD3(w * k, h * k, 1)
            n.opacity = CGFloat(alpha)
        }
        if !boardNode.isHidden { place(boardNode, boardSize, left: 22 * z, top: 22 * z) }
        if !capNode.isHidden { place(capNode, capSize, left: 21 * z, top: H - 22 * z - Float(capSize.height)) }
        winShown += ((winWanted ? 1 : 0) - winShown) * min(1, dt * 5)   // slides up and fades in, like the page's banner
        if winShown < 0.01 && !winWanted { winNode.isHidden = true }
        if !winNode.isHidden {
            place(winNode, winSize, left: (W - Float(winSize.width)) / 2, top: H * 0.96 - Float(winSize.height) + 24 * z * (1 - winShown), alpha: winShown)
        }
        fadeNode.simdPosition = SIMD3(0, 0, -d * 0.999)
        fadeNode.simdScale = SIMD3(W * k * 1.2, H * k * 1.2, 1)
        fadeNode.opacity = CGFloat(max(0, min(1, fade)))
        fadeNode.isHidden = fade <= 0.001
    }
}
