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

func shoot(_ kind: Flock.Kind, _ cfg: SaverConfig, _ name: String, seconds: Double, closeup: Float? = nil, deploy: Float? = nil) {
    let f = Flock(kind: kind, cfg: cfg, resources: res)
    if let e = f.error { print("SCENE ERROR \(name):", e) }
    f.setAspect(size.width / size.height)
    let r = SCNRenderer(device: device, options: nil)
    r.scene = f.scene
    r.pointOfView = f.camera
    var t = 0.0
    f.step(to: t)
    if let d = closeup { f.closeup(distance: d, deploy: deploy) }
    while t < seconds { t += 1.0 / 30; f.step(to: t) }
    let img = r.snapshot(atTime: t, with: size, antialiasingMode: .multisampling4X)
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { print("NO IMAGE \(name)"); return }
    print("IMG_BEGIN \(name).jpg"); print(jpg.base64EncodedString()); print("IMG_END")
}

var cars = SaverConfig(); cars.count = 7
shoot(.cars, cars, "native_cars", seconds: 4)
cars.clouds = true
shoot(.cars, cars, "cars_clouds", seconds: 6)
var ships = SaverConfig(); ships.count = 5; ships.oxidation = 0.8; ships.tilt = 30
shoot(.starships, ships, "native_ships", seconds: 4)
var rc = SaverConfig(); rc.count = 1; rc.roadster = true
for (name, t) in [("roadster_a", 1.0), ("roadster_b", 3.5), ("roadster_c", 6.0)] {
    let f = Flock(kind: .starships, cfg: rc, resources: res)
    if let e = f.error { print("SCENE ERROR roadster:", e) }
    f.setAspect(size.width / size.height)
    let r = SCNRenderer(device: device, options: nil); r.scene = f.scene; r.pointOfView = f.camera
    var tt = 0.0; f.step(to: tt); f.roadsterCloseup(distance: 12)
    while tt < t { tt += 1.0 / 30; f.step(to: tt) }
    let img = r.snapshot(atTime: tt, with: size, antialiasingMode: .multisampling4X)
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
        print("IMG_BEGIN \(name).jpg"); print(jpg.base64EncodedString()); print("IMG_END")
    }
}
var rs = SaverConfig(); rs.count = 5; rs.roadster = true
shoot(.starships, rs, "ships_roadster", seconds: 5)
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
c3.liveries = ["v2"]
shoot(.starlink, c3, "close_v2", seconds: 1.3, closeup: 26)
c3.liveries = ["deploy"]
shoot(.starlink, c3, "dep_a", seconds: 1.3, closeup: 22, deploy: -1)
shoot(.starlink, c3, "dep_b", seconds: 1.3, closeup: 26, deploy: 1.7)
shoot(.starlink, c3, "dep_c", seconds: 1.3, closeup: 40, deploy: 3.4)
shoot(.starlink, c3, "dep_d", seconds: 1.3, closeup: 40, deploy: 5.0)
var c6 = SaverConfig(); c6.count = 1; c6.liveries = ["v15"]
shoot(.starlink, c6, "close_v15a", seconds: 1.0, closeup: 18)
shoot(.starlink, c6, "close_v15b", seconds: 1.55, closeup: 18)
c6.count = 8; c6.liveries = ["v15", "v2", "v3"]; c6.lasers = true
shoot(.starlink, c6, "sats_v15", seconds: 8)
var c5 = SaverConfig(); c5.count = 12; c5.liveries = ["v15", "v2", "v3"]; c5.crossing = true; c5.lasers = true
shoot(.starlink, c5, "sats_x_a", seconds: 6)
shoot(.starlink, c5, "sats_x_b", seconds: 14)
print("DONE")
