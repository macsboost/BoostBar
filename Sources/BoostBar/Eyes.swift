import AppKit
import Network

/// The moods the eyes can show. Each is set off by something the Mac is doing (or, for a few, by an event).
enum Emotion: String, CaseIterable {
    case sleepy, alarmed, angry, sweating, happy, sad, suspicious, skeptical, startled, bored, hearts

    var title: String {
        switch self {
        case .sleepy: return "Sleepy"
        case .alarmed: return "Alarmed"
        case .angry: return "Angry"
        case .sweating: return "Sweating"
        case .happy: return "Happy"
        case .sad: return "Sad"
        case .suspicious: return "Suspicious"
        case .skeptical: return "Skeptical (one-eye squint)"
        case .startled: return "Startled"
        case .bored: return "Bored"
        case .hearts: return "Heart / dollar eyes"
        }
    }
    /// When it shows, for the Settings tooltip.
    var when: String {
        switch self {
        case .sleepy: return "Lids droop the longer the Mac sits idle (from 3 minutes)."
        case .alarmed: return "Wide eyes, tiny pupils: CPU pegged, or battery at 10% and unplugged."
        case .angry: return "Slanted lids when the CPU has been in the red for 20 seconds."
        case .sweating: return "A squint and a sweat drop when the Mac is running hot."
        case .happy: return "Smiling eyes for a few seconds when the charger is plugged in or a big download finishes."
        case .sad: return "Droopy eyes when the network is down, or the battery is at 15% and unplugged."
        case .suspicious: return "A narrow side-eye when the pointer lingers right by the eyes."
        case .skeptical: return "Whip the pointer fast across a big stretch of screen and one eye squints at it: the eye on the pointer's side, harder the faster you go (both a little when it's right above them)."
        case .startled: return "A jump and a blink when a drive is plugged in, or the pointer moves after a long pause."
        case .bored: return "An eye-roll now and then when nothing has happened for a while."
        case .hearts: return "A flash of hearts and dollar signs when a tip button is clicked."
        }
    }
}

/// How the eyes are drawn for a mood: lids, slant, pupil size and the odd prop.
struct EyeFace: Equatable {
    var lidTop: CGFloat = 0        // fraction of the eye the upper lid covers
    var lidBottom: CGFloat = 0     // …and the lower lid
    var slant: CGFloat = 0         // > 0 angry (lids lower toward the middle), < 0 sad (lower at the outside)
    var pupilScale: CGFloat = 1
    var lift: CGFloat = 0          // points the eyes hop up
    var smile = false              // happy: closed, arched eyes
    var sweat: CGFloat = -1        // 0…1 = a drop sliding down beside the eyes; < 0 none
    var symbol = 0                 // 1 = hearts, 2 = dollar signs, in place of the pupils
    var squintL: CGFloat = 0       // one-eye squint, 0…1, for the left and right eye
    var squintR: CGFloat = 0

    static func pose(_ e: Emotion, level: CGFloat = 1) -> EyeFace {
        var f = EyeFace()
        switch e {
        case .sleepy: f.lidTop = 0.3 + 0.45 * level
        case .alarmed: f.pupilScale = 0.5
        case .angry: f.lidTop = 0.26; f.slant = 0.3
        case .sweating: f.lidTop = 0.12; f.lidBottom = 0.22; f.sweat = 0.3
        case .happy: f.smile = true
        case .sad: f.lidTop = 0.24; f.slant = -0.3
        case .suspicious: f.lidTop = 0.42; f.lidBottom = 0.28
        case .skeptical: f.squintR = level
        case .startled: f.pupilScale = 0.45; f.lift = 1.5
        case .bored: f.lidTop = 0.3
        case .hearts: f.symbol = 1
        }
        return f
    }

    /// Eases the numeric parts toward `to`; the props switch at once.
    mutating func ease(to t: EyeFace, by k: CGFloat) {
        lidTop += (t.lidTop - lidTop) * k
        lidBottom += (t.lidBottom - lidBottom) * k
        slant += (t.slant - slant) * k
        pupilScale += (t.pupilScale - pupilScale) * k
        lift += (t.lift - lift) * k
        squintL += (t.squintL - squintL) * k
        squintR += (t.squintR - squintR) * k
        if abs(squintL - t.squintL) < 0.004 { squintL = t.squintL }
        if abs(squintR - t.squintR) < 0.004 { squintR = t.squintR }
        if abs(lidTop - t.lidTop) < 0.004 { lidTop = t.lidTop }
        if abs(lidBottom - t.lidBottom) < 0.004 { lidBottom = t.lidBottom }
        if abs(slant - t.slant) < 0.004 { slant = t.slant }
        if abs(pupilScale - t.pupilScale) < 0.004 { pupilScale = t.pupilScale }
        if abs(lift - t.lift) < 0.02 { lift = t.lift }
        smile = t.smile; sweat = t.sweat; symbol = t.symbol
    }
}

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

    // MARK: Emotions
    /// Which moods are switched on, and what the app knows that sets them off.
    var emotions: Set<Emotion> = []
    var cpuLoad = 0.0
    var batteryPercent: Int?
    var onCharger = true
    private var face = EyeFace()
    private var triggered: (emotion: Emotion, from: TimeInterval, until: TimeInterval)?
    private var cpuPeggedSince: TimeInterval?, cpuHighSince: TimeInterval?
    private var hoverSince: TimeInterval?
    private var lastIdle = 0.0
    private var nextRoll: TimeInterval = 0, rollStart: TimeInterval = -10
    private var netDown = false
    // Skeptical: a fast, wide sweep of the pointer, and which side of the eyes it's on
    private var trail: [(t: TimeInterval, p: NSPoint)] = []
    private var skeptUntil: TimeInterval = 0, skeptLevel: CGFloat = 0, skeptSide: CGFloat = 0

    /// Watches for the pointer whipping across the screen: fast (over ~2200 pt/s for half a second) and over a big
    /// stretch (the last second's path spans 700+ pt). The faster, the harder the squint; it holds 1.3 s after.
    private func trackWhip(mouse: NSPoint, mid: CGPoint, now: TimeInterval) {
        trail.append((now, mouse))
        trail.removeAll { now - $0.t > 1.0 }
        guard trail.count > 4 else { return }
        var len: CGFloat = 0
        var lo = mouse, hi = mouse
        for k in trail.indices {
            let p = trail[k].p
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
            if k > 0, now - trail[k].t <= 0.5 { len += hypot(p.x - trail[k - 1].p.x, p.y - trail[k - 1].p.y) }
        }
        let speed = len / 0.5, span = hypot(hi.x - lo.x, hi.y - lo.y)
        if speed > 2200, span > 700 {
            skeptLevel = min(1, 0.45 + (speed - 2200) / 5000)
            skeptUntil = now + 1.3
        }
        if now < skeptUntil { skeptSide = mouse.x - mid.x }     // the squint follows the pointer's side
    }
    private var pathMonitor: NWPathMonitor?

    /// Shows a mood for a while because something just happened (a charger, a drive, a tip…).
    func trigger(_ e: Emotion, for seconds: Double, force: Bool = false) {
        guard force || emotions.contains(e) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        triggered = (e, now, now + seconds)
    }

    /// Settings: the pointer left an emotion's checkbox, so stop previewing it.
    func endPreview(_ e: Emotion) {
        if triggered?.emotion == e { triggered = nil }
    }

    /// The mood to show right now, strongest first, and how strongly (sleepy deepens with idle time).
    private func mood(now: TimeInterval, mouse: NSPoint, mid: CGPoint, halfSpan: CGFloat) -> (Emotion, CGFloat)? {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if lastIdle > 60, idle < 1 { trigger(.startled, for: 0.9) }      // woken after a long pause
        lastIdle = idle
        if emotions.contains(.skeptical) { trackWhip(mouse: mouse, mid: mid, now: now) }
        if let t = triggered {
            if now < t.until { return (t.emotion, 1) }
            triggered = nil
        }
        if emotions.contains(.skeptical), now < skeptUntil {
            return (.skeptical, skeptLevel * CGFloat(min(1, (skeptUntil - now) / 0.5)))   // eases off at the end
        }
        if cpuLoad > 0.9 { if cpuPeggedSince == nil { cpuPeggedSince = now } } else { cpuPeggedSince = nil }
        if cpuLoad > 0.8 { if cpuHighSince == nil { cpuHighSince = now } } else if cpuLoad < 0.7 { cpuHighSince = nil }
        let pct = batteryPercent ?? 100
        func on(_ e: Emotion) -> Bool { emotions.contains(e) }
        if on(.alarmed) {
            if let p = cpuPeggedSince, now - p < 6 { return (.alarmed, 1) }
            if !onCharger, pct <= 10, now.truncatingRemainder(dividingBy: 60) < 6 { return (.alarmed, 1) }   // a reminder each minute
        }
        if on(.sweating), ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return (.sweating, 1) }
        if on(.angry), let h = cpuHighSince, now - h > 20 { return (.angry, 1) }
        if on(.sad), netDown || (!onCharger && pct <= 15) { return (.sad, 1) }
        let near = abs(mouse.x - mid.x) < halfSpan + 10 && abs(mid.y - mouse.y) < 14
        if near { if hoverSince == nil { hoverSince = now } } else { hoverSince = nil }
        if on(.suspicious), let h = hoverSince, now - h > 1.2 { return (.suspicious, 1) }
        if on(.bored), idle > 90 {
            if nextRoll == 0 { nextRoll = now + .random(in: 4...15) }
            if now >= nextRoll { rollStart = now; nextRoll = now + .random(in: 25...50) }
            if now - rollStart < 1.6 { return (.bored, CGFloat((now - rollStart) / 1.6)) }
        } else { nextRoll = 0 }
        if on(.sleepy), idle > 180 { return (.sleepy, CGFloat(min(1, (idle - 180) / 420))) }
        return nil
    }

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
        if on, pathMonitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] p in DispatchQueue.main.async { self?.netDown = p.status != .satisfied } }
            m.start(queue: .global(qos: .utility))
            pathMonitor = m
        }
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
    private func trackCircles(mouse: NSPoint, mid: CGPoint, halfSpan: CGFloat, now: TimeInterval) -> Bool {
        let dt = lastStep == 0 ? 1.0 / 30 : min(0.1, now - lastStep)
        lastStep = now
        // only loops drawn right over the eyes count: within the eyes' width (plus a little) and inside the menu bar's height
        let near = abs(mouse.x - mid.x) < halfSpan + 16 && abs(mid.y - mouse.y) < 24
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
        if trackCircles(mouse: mouse, mid: mid, halfSpan: (centers.last!.x - centers.first!.x) / 2 + v.pupilTravel.width + 6, now: now) {
            v.wheelAngle = wheelAngle
            v.pupilOffsets = pos
            face = EyeFace(); v.eyeFace = face
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
                let a: Double = angle + Double(i) * Double.pi            // eyes out of step = extra dizzy
                let r = CGFloat(0.85 * min(1, left / 0.4 + 0.3))
                let cx = CGFloat(Foundation.cos(a)), sy = CGFloat(Foundation.sin(a))
                pos[i] = CGPoint(x: cx * travel.width * r, y: sy * travel.height * r)
                vel[i] = .zero
            }
            changed = true
        }
        // the mood: pose the lids, and let a few moods move the pupils themselves
        var target = EyeFace()
        var startledBlink = false
        if let (emotion, level) = mood(now: now, mouse: mouse, mid: mid, halfSpan: (centers.last!.x - centers.first!.x) / 2 + travel.width + 6), now >= dizzyUntil {
            target = EyeFace.pose(emotion, level: level)
            switch emotion {
            case .bored:
                // the eye-roll: up, and all the way around
                let a = Double(level) * 2 * Double.pi
                let rx = CGFloat(Foundation.sin(a)) * travel.width * 0.85, ry = CGFloat(Foundation.cos(a)) * travel.height * 0.85
                for i in pos.indices { pos[i] = CGPoint(x: rx, y: ry); vel[i] = .zero }
                changed = true
            case .sleepy:
                for i in pos.indices { pos[i].y = max(-travel.height, pos[i].y - travel.height * 0.5 * level) }
            case .sad:
                for i in pos.indices { pos[i].y = min(pos[i].y, -travel.height * 0.45) }
            case .alarmed:
                for i in pos.indices { pos[i].x += .random(in: -0.35...0.35); pos[i].y += .random(in: -0.35...0.35) }
                changed = true
            case .sweating:
                target.sweat = CGFloat((now / 1.6).truncatingRemainder(dividingBy: 1))
                changed = true
            case .skeptical:
                // the eye on the pointer's side squints; with the pointer right above the eyes, both do a little
                let w = min(1, abs(skeptSide) / 250)
                let main = level, other = level * (1 - w) * 0.6
                if skeptSide < 0 { target.squintL = main; target.squintR = other } else { target.squintR = main; target.squintL = other }
                target.squintR = triggered?.emotion == .skeptical ? level : target.squintR    // "Try one": the right eye
            case .startled:
                let t = now - (triggered?.from ?? now)
                target.lift = t < 0.22 ? 1.5 : 0
                startledBlink = t > 0.45 && t < 0.6
            case .hearts:
                target.symbol = Int((now - (triggered?.from ?? now)) / 1.2) % 2 == 0 ? 1 : 2
                target.pupilScale = 1 + 0.18 * CGFloat(Foundation.sin(now * 9))       // a little pulse
                changed = true
            default: break
            }
        }
        let before = face
        face.ease(to: target, by: 0.28)
        if face != before || face != v.eyeFace { changed = true }
        var closed = startledBlink
        if blink, !closed, !face.smile {
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
            v.eyeFace = face
            v.eyesClosed = closed
            v.needsDisplay = true
        }
    }
}
