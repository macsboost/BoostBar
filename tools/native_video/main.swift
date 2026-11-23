// Records a native screen saver scene (the same SceneKit/Metal code the .saver runs) to an H.264 .mp4 at 60 fps,
// rendering each frame off-screen with 4x multisampling — smooth video for the README and sharing.
// usage: native_video <resources dir> <out.mp4> <cars|starships|starlink> <seconds> '<json config>'
import AppKit
import AVFoundation
import Metal
import SceneKit

let args = CommandLine.arguments
let res = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let kind: Flock.Kind = args[3] == "cars" ? .cars : args[3] == "starships" ? .starships : .starlink
let seconds = Double(args[4]) ?? 12
let j = (try? JSONSerialization.jsonObject(with: Data((args.count > 5 ? args[5] : "{}").utf8))) as? [String: Any] ?? [:]
var cfg = SaverConfig()
cfg.count = j["count"] as? Int ?? cfg.count
cfg.liveries = j["liveries"] as? [String] ?? cfg.liveries
cfg.speed = j["speed"] as? Double ?? cfg.speed
cfg.flapSpeed = j["flapSpeed"] as? Double ?? cfg.flapSpeed
cfg.stunts = j["stunts"] as? Bool ?? cfg.stunts
cfg.oxidation = j["oxidation"] as? Double ?? cfg.oxidation
cfg.crossing = j["crossing"] as? Bool ?? false
cfg.lasers = j["lasers"] as? Bool ?? false
let W = j["width"] as? Int ?? 1920, H = j["height"] as? Int ?? 1080, fps = 60
let warm = j["warmup"] as? Double ?? 4

guard let device = MTLCreateSystemDefaultDevice() else { print("NO METAL"); exit(1) }
let f = Flock(kind: kind, cfg: cfg, resources: res)
if let e = f.error { print("SCENE ERROR", e); exit(1) }
f.setAspect(CGFloat(W) / CGFloat(H))
let r = SCNRenderer(device: device, options: nil)
r.scene = f.scene
r.pointOfView = f.camera

try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                      AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var t = 0.0
f.step(to: t)
while t < warm { t += 1.0 / Double(fps); f.step(to: t) }      // let the flock spread out and the links form
let frames = Int(seconds * Double(fps))
let start = Date()
for i in 0..<frames {
    t += 1.0 / Double(fps)
    f.step(to: t)
    let img = r.snapshot(atTime: t, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("NO FRAME", i); continue }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let buf = pb else { continue }
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    CVPixelBufferUnlockBaseAddress(buf, [])
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    if i % 120 == 0 { print("frame \(i)/\(frames)  \(String(format: "%.1f", Date().timeIntervalSince(start)))s") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("WROTE", out.path, writer.status.rawValue, writer.error?.localizedDescription ?? "")
