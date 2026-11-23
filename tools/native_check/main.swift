// Renders each native screen saver scene off-screen with Metal (SCNRenderer) and prints JPEG frames as base64,
// so CI can check the SceneKit version without a screen saver host.
// build: swiftc -O -parse-as-library? (no: top-level code) tools/native_check/main.swift Saver/native/*.swift -o native_check
import AppKit
import Metal
import SceneKit

let res = URL(fileURLWithPath: CommandLine.arguments[1])
guard let device = MTLCreateSystemDefaultDevice() else { print("NO METAL DEVICE"); exit(1) }
print("METAL:", device.name)
let size = CGSize(width: 1280, height: 720)

func shoot(_ kind: Flock.Kind, _ cfg: SaverConfig, _ name: String, seconds: Double, closeup: Float? = nil) {
    let f = Flock(kind: kind, cfg: cfg, resources: res)
    if let e = f.error { print("SCENE ERROR \(name):", e) }
    f.setAspect(size.width / size.height)
    let r = SCNRenderer(device: device, options: nil)
    r.scene = f.scene
    r.pointOfView = f.camera
    var t = 0.0
    f.step(to: t)
    if let d = closeup { f.closeup(distance: d) }
    while t < seconds { t += 1.0 / 30; f.step(to: t) }
    let img = r.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X)
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { print("NO IMAGE \(name)"); return }
    print("IMG_BEGIN \(name).jpg"); print(jpg.base64EncodedString()); print("IMG_END")
}

var cars = SaverConfig(); cars.count = 7
shoot(.cars, cars, "native_cars", seconds: 4)
var ships = SaverConfig(); ships.count = 5; ships.oxidation = 0.8; ships.tilt = 30
shoot(.starships, ships, "native_ships", seconds: 4)
var sats = SaverConfig(); sats.count = 5
shoot(.starlink, sats, "native_sats", seconds: 4)
var c1 = SaverConfig(); c1.count = 3; c1.liveries = ["macsboost"]
shoot(.cars, c1, "close_car", seconds: 1.3, closeup: 14)
var c2 = SaverConfig(); c2.count = 1; c2.oxidation = 0.6; c2.tilt = 30; c2.stunts = false
shoot(.starships, c2, "close_ship", seconds: 1.3, closeup: 22)
var c4 = SaverConfig(); c4.count = 1; c4.oxidation = 0.0; c4.stunts = false
shoot(.starships, c4, "close_ship2", seconds: 2.1, closeup: 22)
var c3 = SaverConfig(); c3.count = 1; c3.liveries = ["v3"]; c3.stunts = false
shoot(.starlink, c3, "close_sat", seconds: 1.3, closeup: 40)
print("DONE")
