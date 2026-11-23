import AppKit

/// Drives the googly eyes in the menu bar: pupils look toward the mouse pointer anywhere on
/// screen (NSEvent.mouseLocation — no permission needed), with springy "googly" overshoot,
/// a little droop, and an occasional blink. Redraws only when something actually moves.
final class EyesAnimator {
    weak var view: StatusGraphView?
    var googly = true
    var blink = true
    /// true: each eye tracks the pointer from its own center (they go cross-eyed when the pointer
    /// is between them). false: both eyes look the same way, aimed from the midpoint between them.
    var allowCrossEye = true
    /// Lazy eyes take their time: where they're looking drifts slowly after the pointer.
    var lazy = false
    private var lazyTarget: [CGPoint] = []

    private var timer: Timer?
    private var pos: [CGPoint] = []
    private var vel: [CGPoint] = []
    private var lastMouse = NSPoint(x: CGFloat.nan, y: CGFloat.nan)
    private var nextBlink: TimeInterval = 0
    private var blinkUntil: TimeInterval = 0

    var isRunning: Bool { timer != nil }

    /// Eyes squeeze shut while the Mac is being shaken…
    var shaking = false { didSet { if oldValue && !shaking { dizzyUntil = ProcessInfo.processInfo.systemUptime + 1.8 } } }
    /// …then pop open with the pupils spinning for a moment.
    private var dizzyUntil: TimeInterval = 0

    // MARK: Circle-to-spin
    // Draw two and a half loops with the pointer near the eyes and the pupils start riding an internal wheel on a vertical
    // axis, at a speed that follows how fast you circle. Stop circling and the wheel coasts down, then the pupils
    // snap back to following the pointer.
    private var lastSample = NSPoint(x: CGFloat.nan, y: CGFloat.nan)
    private var lastHeading: CGFloat?
    private var winding: CGFloat = 0            // radians the pointer's heading has turned, one direction
    private var lastTurnAt: TimeInterval = 0
    private var turnRate: CGFloat = 0           // smoothed, rad/s
    private var spinning = false
    private var wheelAngle: CGFloat = 0
    private var wheelVel: CGFloat = 0           // rad/s
    private var lastStep: TimeInterval = 0

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

    /// Follows the pointer's heading; returns true while the eyes are in wheel mode (and advances the wheel).
    private func trackCircles(mouse: NSPoint, mid: CGPoint, now: TimeInterval) -> Bool {
        let dt = lastStep == 0 ? 1.0 / 30 : min(0.1, now - lastStep)
        lastStep = now
        let near = abs(mouse.x - mid.x) < 420 && mid.y - mouse.y < 480
        var circling = false
        if lastSample.x.isNaN { lastSample = mouse }
        let dx = mouse.x - lastSample.x, dy = mouse.y - lastSample.y
        if hypot(dx, dy) >= 3 {
            let h = atan2(dy, dx)
            if let lh = lastHeading, near {
                var d = h - lh
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                // keep winding in one direction; a turn the other way (beyond jitter) starts over
                if d != 0, (winding == 0 || (d > 0) == (winding > 0) || abs(d) < 0.15) {
                    winding += d
                } else if abs(d) >= 0.15 {
                    winding = d
                }
                let rate = d / CGFloat(dt)
                turnRate += (rate - turnRate) * 0.25
                if abs(d) > 0.02 { lastTurnAt = now }
            } else if !near {
                winding = 0
            }
            lastHeading = h
            lastSample = mouse
        }
        if now - lastTurnAt > 0.45 {           // stopped circling
            winding = 0
            turnRate *= 0.7
        } else {
            circling = abs(turnRate) > 2.0
        }

        if !spinning, abs(winding) >= 5 * .pi {  // two and a half loops
            spinning = true
            wheelVel = 0
            wheelAngle = 0
        }
        guard spinning else { return false }

        if circling {
            // spin with the circles: faster loops, faster wheel (and the same way round)
            let target = max(-20, min(20, turnRate * 1.15))
            wheelVel += (target - wheelVel) * 0.12
        } else {
            wheelVel *= CGFloat(pow(0.55, dt))   // inertia: coasts down over a few seconds
        }
        wheelAngle += wheelVel * CGFloat(dt)
        if !circling, abs(wheelVel) < 0.9 {
            spinning = false
            winding = 0
            return false
        }
        return true
    }

    private func step() {
        guard let v = view, let centers = v.eyeCentersOnScreen(), !centers.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        if pos.count != centers.count {
            pos = Array(repeating: .zero, count: centers.count)
            vel = Array(repeating: .zero, count: centers.count)
        }
        if lazyTarget.count != centers.count { lazyTarget = pos }
        let travel = v.pupilTravel
        var changed = mouse != lastMouse
        let mid = CGPoint(x: centers.map(\.x).reduce(0, +) / CGFloat(centers.count),
                          y: centers.map(\.y).reduce(0, +) / CGFloat(centers.count))
        // Pointer right between the eyes (and close)? Go fully cross-eyed.
        let betweenEyes = centers.count > 1 && allowCrossEye
            && mouse.x > (centers.first!.x) && mouse.x < (centers.last!.x) && abs(mouse.y - mid.y) < 30
        for i in centers.indices {
            let origin = allowCrossEye ? centers[i] : mid
            let dx = mouse.x - origin.x
            let dy = mouse.y - origin.y
            let dist = hypot(dx, dy)
            let reach = betweenEyes ? 1 : min(1, dist / 60)
            var target = dist > 0.01
                ? CGPoint(x: dx / dist * travel.width * reach, y: dy / dist * travel.height * reach)
                : .zero
            if lazy {
                // ease toward the pointer's direction over a second or so instead of snapping to it
                lazyTarget[i].x += (target.x - lazyTarget[i].x) * 0.035
                lazyTarget[i].y += (target.y - lazyTarget[i].y) * 0.035
                if hypot(target.x - lazyTarget[i].x, target.y - lazyTarget[i].y) > 0.02 { changed = true }
                target = lazyTarget[i]
            } else {
                lazyTarget[i] = target
            }
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
        if trackCircles(mouse: mouse, mid: mid, now: now) {
            v.wheelAngle = wheelAngle
            v.pupilOffsets = pos
            v.eyesClosed = shaking
            v.needsDisplay = true
            lastMouse = mouse
            return
        }
        if v.wheelAngle != nil {
            v.wheelAngle = nil
            // snap back: kick the springs so the pupils boing back toward the pointer
            for i in vel.indices { vel[i] = CGPoint(x: CGFloat.random(in: -2...2), y: CGFloat.random(in: -1.5...1.5)) }
            changed = true
        }
        if now < dizzyUntil {
            // dizzy: pupils whirl around the rim, slowing down as it wears off
            let left = dizzyUntil - now
            let angle = left * left * 7 + left * 9
            for i in pos.indices {
                let a = angle + Double(i) * .pi            // eyes out of step = extra dizzy
                let r = 0.85 * min(1, left / 0.4 + 0.3)
                pos[i] = CGPoint(x: cos(a) * travel.width * r, y: sin(a) * travel.height * r)
                vel[i] = .zero
            }
            changed = true
        }
        var closed = false
        if blink {
            if nextBlink == 0 { nextBlink = now + Double.random(in: 3...8) }
            if now >= nextBlink {
                blinkUntil = now + 0.13
                nextBlink = now + Double.random(in: 3.5...9)
            }
            closed = now < blinkUntil
        }
        if shaking { closed = true }
        if closed != v.eyesClosed { changed = true }

        lastMouse = mouse
        if changed {
            v.pupilOffsets = pos
            v.eyesClosed = closed
            v.needsDisplay = true
        }
    }
}
