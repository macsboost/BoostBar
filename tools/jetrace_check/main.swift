// Renders the native Jet Racers screen saver off-screen with Metal (SCNRenderer) — the same SceneKit code and race
// script the .saver runs — and writes JPEG frames, so CI can check it without a screen saver host.
//   swiftc -O tools/jetrace_check/main.swift Saver/native/GLB.swift Saver/native/JetRace.swift -o jetrace_check
//   jetrace_check <resources dir> <out dir>      resources: three.min.js, jetrace.js, rigs.json and the six .glb models
import AppKit
import Metal
import SceneKit

let res = URL(fileURLWithPath: CommandLine.arguments[1]), outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let device: MTLDevice = {
    guard let d = MTLCreateSystemDefaultDevice() else { print("NO METAL DEVICE"); exit(1) }
    return d
}()
print("METAL:", device.name)
let size = CGSize(width: 1280, height: 720)
var failed = false

/// A frame as JPEG, showing what reaches the screen. The frame buffer's alpha is dropped rather than flattened: a
/// screen saver's view is opaque, and JPEG conversion would otherwise wash every see-through thing (spray, wakes, the
/// scoreboard) towards white.
func jpeg(_ img: NSImage, quality: Double = 0.8) -> Data? {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let space = cg.colorSpace, let provider = cg.dataProvider else { return nil }
    let first = [CGImageAlphaInfo.premultipliedFirst, .first, .noneSkipFirst].contains(cg.alphaInfo)
    let info = (cg.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | (first ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.noneSkipLast).rawValue
    guard let opaque = CGImage(width: cg.width, height: cg.height, bitsPerComponent: cg.bitsPerComponent, bitsPerPixel: cg.bitsPerPixel, bytesPerRow: cg.bytesPerRow,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
    return NSBitmapImageRep(cgImage: opaque).representation(using: .jpeg, properties: [.compressionFactor: quality])
}

final class Take {
    let name: String
    let race: JetRace
    let renderer: SCNRenderer
    var t = 0.0

    init(_ name: String, _ cfg: JetRaceConfig) {
        self.name = name
        let start = Date()
        race = JetRace(cfg: cfg, resources: res)
        if let e = race.error { print("SCENE ERROR \(name):", e); failed = true }
        print("\(name): started in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        race.setView(size: size, scale: 1)
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = race.scene
        renderer.pointOfView = race.camera
        race.step(to: 0)
    }

    var state: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(race.state.utf8))) as? [String: Any] ?? [:] }
    var order: [Int] { (state["order"] as? [NSNumber] ?? []).map(\.intValue) }

    /// Plays on for a while, frame by frame.
    func run(_ seconds: Double) {
        let end = t + seconds
        while t < end { t += 1.0 / 30; race.step(to: t) }
    }

    /// Jumps the race ahead without drawing, then plays a moment so the picture catches up.
    func skip(_ seconds: Double, settle: Double = 2) { race.skip(seconds: seconds); run(settle) }

    /// Jumps to the moment the first racer crosses the line.
    func toFinish() {
        var n = 0
        while order.isEmpty && n < 400 { race.skip(seconds: 0.5); n += 1 }
        run(1.0 / 30)
    }

    func shot(_ label: String) {
        let img = renderer.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X)
        guard let jpg = jpeg(img) else { print("NO IMAGE \(name)_\(label)"); failed = true; return }
        try? jpg.write(to: outDir.appendingPathComponent("\(name)_\(label).jpg"))
        let s = state
        print("\(name)_\(label): phase \(s["phase"] ?? "?") t \(s["t"] ?? 0) shot \(s["shot"] ?? "?") order \(order) celebration \(s["celeb"] ?? "?")")
    }
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// a race as it plays by default: the line-up, the start, and a few moments out on the course
do {
    let a = Take("race", JetRaceConfig())
    a.run(1.5); a.shot("lineup")
    var n = 0
    while (a.state["phase"] as? String) == "grid" && n < 400 { a.run(1.0 / 30); n += 1 }
    a.run(0.2); a.shot("band")
    a.run(1.6); a.shot("start")
    a.skip(12); a.shot("lap_a")
    a.skip(14); a.shot("lap_b")
    a.skip(17); a.shot("lap_c")
    let start = Date(); var frames = 0
    for _ in 0..<600 { a.t += 1.0 / 60; a.race.step(to: a.t); frames += 1 }
    print(String(format: "race: %.2f ms per frame for the race script and scene updates (no drawing)", Date().timeIntervalSince(start) * 1000 / Double(frames)))
}

// the winner option and the celebrations: #8 set to win, backflip
do {
    var c = JetRaceConfig(); c.winner = "8"; c.celebration = "backflip"; c.captions = true
    let b = Take("win8", c)
    b.run(1); b.toFinish()
    if b.order.first != 8 { print("WRONG WINNER: wanted 8, got \(b.order)"); failed = true }
    b.run(2.0); b.shot("spinout")
    b.run(2.6); b.shot("celebrate_a")
    b.run(0.75); b.shot("celebrate_b")
    b.run(2.4); b.shot("celebrate_c")
}
for (id, celebration) in [("16", "bow2"), ("3", "dab"), ("8", "mower"), ("3", "cart")] {
    var c = JetRaceConfig(); c.winner = id; c.celebration = celebration
    let w = Take("win\(id)_\(celebration)", c)
    w.run(1); w.toFinish()
    if w.order.first != Int(id) { print("WRONG WINNER: wanted \(id), got \(w.order)"); failed = true }
    w.run(5.6); w.shot("a")
    w.run(2.4); w.shot("b")
}

// the fixed cameras, mid-race
for cam in ["chase", "onboard", "side", "front", "heli", "blimp", "buoy", "orbit", "finish"] {
    var c = JetRaceConfig(); c.camera = cam; c.follow = "16"; c.board = cam != "blimp"
    let k = Take("cam_\(cam)", c)
    k.run(1); k.skip(34, settle: 2.5); k.shot("a")
}
// PROBE (temporary): which way of handing the wake's and spray's colour to SceneKit blends properly?
do {
    let scene = SCNScene(); scene.background.contents = NSColor.black
    let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.usesOrthographicProjection = true; cam.camera?.orthographicScale = 2.2
    cam.simdPosition = SIMD3(0, 0, 10); scene.rootNode.addChildNode(cam)
    let back = SCNPlane(width: 9, height: 1.2)
    let bm = SCNMaterial(); bm.lightingModel = .constant; bm.diffuse.contents = NSColor(srgbRed: 0.1, green: 0.25, blue: 0.7, alpha: 1); back.materials = [bm]
    let bn = SCNNode(geometry: back); bn.simdPosition = SIMD3(0, 0, -1); scene.rootNode.addChildNode(bn)
    let pos: [Float] = [-0.4, -0.4, 0, 0.4, -0.4, 0, 0.4, 0.4, 0, -0.4, 0.4, 0]
    let idx: [UInt32] = [0, 1, 2, 0, 2, 3]
    let dot: [Float] = [0, 0, 0.4, 1, 1, 0, 0.4, 1, 1, 1, 0.4, 1, 0, 1, 0.4, 1]            // u, v, alpha
    let ribbon: [Float] = [0, 0.1, 1, 1, 1, 0.1, 1, 1, 1, 0.7, 1, 1, 0, 0.7, 1, 1]          // edge, age, strength
    let simple = JetRace.unlit(geometry: JetRace.passData, fragment: "#pragma varyings\nfloat3 wpos;\nfloat3 vdat;\n#pragma body\n{\n_output.color = float4(in.vdat * 0.4, 0.4);\n}\n")
    simple.blendMode = .alpha; simple.writesToDepthBuffer = false; simple.transparency = 0.999
    let list: [(SCNMaterial, [Float])] = [
        (simple, dot), (JetRace.makeSpray("fragment"), dot), (JetRace.makeSpray("surface"), dot), (JetRace.makeSpray("surfacepm"), dot),
        (JetRace.makeFoam("fragment"), ribbon), (JetRace.makeFoam("surface"), ribbon), (JetRace.makeFoam("surfacepm"), ribbon),
    ]
    for (i, v) in list.enumerated() {
        v.0.setValue(NSNumber(value: 1.5), forKey: "uT")
        let n = SCNNode(geometry: JetRace.dataMesh(positions: pos, data: v.1, indices: idx, material: v.0))
        n.simdPosition = SIMD3(Float(i) * 0.9 - 2.7, 0, 0)
        scene.rootNode.addChildNode(n)
    }
    let r = SCNRenderer(device: device, options: nil); r.scene = scene; r.pointOfView = cam
    let img = r.snapshot(atTime: 0, with: size, antialiasingMode: .none)
    if let jpg = jpeg(img, quality: 0.9) { try? jpg.write(to: outDir.appendingPathComponent("probe.jpg")) }
    print("PROBE over blue: plain alpha 0.4 | spray: fragment, surface, surface premultiplied | wake: fragment, surface, surface premultiplied")
}
for mode in ["surface", "surfacepm"] {
    setenv("JETRACE_FX", mode, 1)
    let a = Take("fx_\(mode)", JetRaceConfig())
    var n = 0
    while (a.state["phase"] as? String) == "grid" && n < 400 { a.run(1.0 / 30); n += 1 }
    a.run(1.8); a.shot("start")
    a.skip(12); a.shot("lap")
}
unsetenv("JETRACE_FX")
print(failed ? "FAILED" : "DONE")
exit(failed ? 1 : 0)
