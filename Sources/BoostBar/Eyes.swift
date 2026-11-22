import AppKit

/// Drives the googly eyes in the menu bar: pupils look toward the mouse pointer anywhere on
/// screen (NSEvent.mouseLocation — no permission needed), with springy "googly" overshoot,
/// a little droop, and an occasional blink. Redraws only when something actually moves.
final class EyesAnimator {
    weak var view: StatusGraphView?
    var googly = true
    var blink = true

    private var timer: Timer?
    private var pos: [CGPoint] = []
    private var vel: [CGPoint] = []
    private var lastMouse = NSPoint(x: .nan, y: .nan)
    private var nextBlink: TimeInterval = 0
    private var blinkUntil: TimeInterval = 0

    var isRunning: Bool { timer != nil }

    func setRunning(_ on: Bool) {
        if on, timer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
            t.tolerance = 0.005
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func step() {
        guard let v = view, let centers = v.eyeCentersOnScreen(), !centers.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        if pos.count != centers.count {
            pos = Array(repeating: .zero, count: centers.count)
            vel = Array(repeating: .zero, count: centers.count)
        }
        let travel = v.pupilTravel
        var changed = mouse != lastMouse
        for i in centers.indices {
            let dx = mouse.x - centers[i].x
            let dy = mouse.y - centers[i].y
            let dist = hypot(dx, dy)
            let reach = min(1, dist / 60)
            var target = dist > 0.01
                ? CGPoint(x: dx / dist * travel.width * reach, y: dy / dist * travel.height * reach)
                : .zero
            if googly {
                target.y -= travel.height * 0.18          // googly pupils sag a little
                vel[i].x = (vel[i].x + (target.x - pos[i].x) * 0.22) * 0.80
                vel[i].y = (vel[i].y + (target.y - pos[i].y) * 0.22) * 0.80
                pos[i].x += vel[i].x
                pos[i].y += vel[i].y
                // keep the pupil inside the eye (elliptical clamp)
                let nx = pos[i].x / max(travel.width, 0.1), ny = pos[i].y / max(travel.height, 0.1)
                let r = hypot(nx, ny)
                if r > 1 {
                    pos[i].x /= r; pos[i].y /= r
                    vel[i].x *= -0.5; vel[i].y *= -0.5     // bounce off the rim
                }
                if abs(vel[i].x) > 0.01 || abs(vel[i].y) > 0.01 { changed = true }
            } else if pos[i] != target {
                pos[i] = target
                changed = true
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        var closed = false
        if blink {
            if nextBlink == 0 { nextBlink = now + Double.random(in: 3...8) }
            if now >= nextBlink {
                blinkUntil = now + 0.13
                nextBlink = now + Double.random(in: 3.5...9)
            }
            closed = now < blinkUntil
        }
        if closed != v.eyesClosed { changed = true }

        lastMouse = mouse
        if changed {
            v.pupilOffsets = pos
            v.eyesClosed = closed
            v.needsDisplay = true
        }
    }
}
