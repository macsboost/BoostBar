import AppKit

/// Drawn inside the NSStatusItem button. Each segment can be turned on/off:
///  [●] [ upload ↑ | download ↓ ] ▲ 12 KB/s   8.4W   ● ●
///                                ▼ 340 KB/s   OUT   ● ●   ← disk LEDs
final class StatusGraphView: NSView {
    enum AwakeState { case normal, keepAwake, lidAwake }
    enum Target: Equatable { case network, battery, disk(String) }

    struct LED { let key: String; let color: NSColor }

    // Content
    var up: [Double] = []
    var down: [Double] = []
    var upText = "0.0 KB/s"
    var downText = "0.0 KB/s"
    var awake: AwakeState = .normal
    var battery: BatteryReading?
    var leds: [LED] = []
    var litKeys: Set<String> = []

    // Appearance
    var upColor: NSColor = .white
    var downColor: NSColor = .white

    // Which segments to show
    var showNetwork = true
    var showBattery = false
    var showDisks = true
    var showEyes = false

    /// Disk LED size: 0 = small (two rows), 1 = medium, 2 = large
    var ledSize = 0

    // Googly eyes
    var eyeSize = 1            // 0 small, 1 medium, 2 large
    var singleEye = false
    var pupilOffsets: [CGPoint] = []
    var eyesClosed = false

    // Hover callbacks (point is in this view's coordinates)
    var onHover: ((Target?) -> Void)?
    var onExit: (() -> Void)?

    static let chargeColor = NSColor.systemGreen
    static let dischargeColor = NSColor.systemOrange

    private static let pad: CGFloat = 3
    private static let dotWidth: CGFloat = 6
    private static let graphWidth: CGFloat = 30
    private static let netTextWidth: CGFloat = 58
    private static let batteryWidth: CGFloat = 30
    private static let iconWidth: CGFloat = 20
    private static let ledDiameters: [CGFloat] = [7, 11, 15]
    private static let eyeSizes: [NSSize] = [NSSize(width: 9, height: 13), NSSize(width: 12, height: 17), NSSize(width: 15, height: 20)]

    private var showsBattery: Bool { showBattery && battery != nil }
    private var showsDisks: Bool { showDisks && !leds.isEmpty }
    private var showsAnything: Bool { showNetwork || showsBattery || showsDisks || showEyes }

    /// Segment rects in this view's coordinates.
    private(set) var networkRect = NSRect.zero
    private(set) var batteryRect = NSRect.zero
    private(set) var diskRect = NSRect.zero
    private(set) var eyesRect = NSRect.zero
    private var ledRects: [(key: String, rect: NSRect)] = []
    private var eyeRects: [NSRect] = []

    private var eyeDims: NSSize { Self.eyeSizes[min(max(eyeSize, 0), 2)] }
    private var pupilRadius: CGFloat { eyeDims.width * 0.27 }

    /// How far a pupil may move from the eye's center (points).
    var pupilTravel: CGSize {
        CGSize(width: eyeDims.width / 2 - pupilRadius - 1, height: eyeDims.height / 2 - pupilRadius - 1)
    }

    /// Screen-space centers of each eye, for aiming the pupils at the mouse.
    func eyeCentersOnScreen() -> [CGPoint]? {
        guard let win = window, !eyeRects.isEmpty else { return nil }
        return eyeRects.map { r in
            let s = win.convertToScreen(convert(r, to: nil))
            return CGPoint(x: s.midX, y: s.midY)
        }
    }

    /// Lays out the segments and returns the total width the status item needs.
    @discardableResult
    func layoutSegments(height h: CGFloat) -> CGFloat {
        var x = Self.pad
        if awake != .normal || !showsAnything { x += Self.dotWidth }
        networkRect = .zero; batteryRect = .zero; diskRect = .zero; eyesRect = .zero; ledRects = []; eyeRects = []
        if !showsAnything { return x + Self.iconWidth + Self.pad }

        var first = true
        func gap() { if !first { x += 4 }; first = false }

        if showEyes {
            gap()
            let e = eyeDims
            let eh = min(e.height, h - 2)
            let count = singleEye ? 1 : 2
            for i in 0..<count {
                eyeRects.append(NSRect(x: x + CGFloat(i) * (e.width + 1), y: (h - eh) / 2, width: e.width, height: eh))
            }
            eyesRect = NSRect(x: x, y: 0, width: CGFloat(count) * e.width + CGFloat(count - 1), height: h)
            x = eyesRect.maxX
        }

        if showNetwork {
            gap()
            networkRect = NSRect(x: x, y: 0, width: Self.graphWidth + 4 + Self.netTextWidth, height: h)
            x = networkRect.maxX
        }
        if showsBattery {
            gap()
            batteryRect = NSRect(x: x, y: 0, width: Self.batteryWidth, height: h)
            x = batteryRect.maxX
        }
        if showsDisks {
            gap()
            // Small LEDs stack in two rows when there are several drives; medium/large use one row.
            let dia = Self.ledDiameters[min(max(ledSize, 0), 2)]
            let cell = dia + 2
            let rows = (ledSize == 0 && leds.count > 1) ? 2 : 1
            let cols = Int(ceil(Double(leds.count) / Double(rows)))
            diskRect = NSRect(x: x, y: 0, width: CGFloat(cols) * cell + 1, height: h)
            for (i, led) in leds.enumerated() {
                let col = i / rows, row = i % rows
                let cy: CGFloat = rows == 1 ? h / 2 : (row == 0 ? h / 2 + 4.5 : h / 2 - 4.5)
                let rect = NSRect(x: x + CGFloat(col) * cell + 1.5, y: cy - dia / 2, width: dia, height: dia)
                ledRects.append((led.key, rect))
            }
            x = diskRect.maxX
        }
        return x + Self.pad
    }

    func target(at p: NSPoint) -> Target? {
        if networkRect.insetBy(dx: -2, dy: 0).contains(p) { return .network }
        if batteryRect.insetBy(dx: -2, dy: 0).contains(p) { return .battery }
        if diskRect.insetBy(dx: -2, dy: 0).contains(p) {
            // nearest LED to the pointer
            return ledRects.min(by: { hypot($0.rect.midX - p.x, $0.rect.midY - p.y) < hypot($1.rect.midX - p.x, $1.rect.midY - p.y) })
                .map { .disk($0.key) }
        }
        return nil
    }

    /// Screen rect of a segment (for anchoring the hover panel).
    func screenRect(for t: Target) -> NSRect? {
        let r: NSRect
        switch t {
        case .network: r = networkRect
        case .battery: r = batteryRect
        case .disk(let k): r = ledRects.first(where: { $0.key == k })?.rect.insetBy(dx: -4, dy: -8) ?? diskRect
        }
        guard !r.isEmpty, let win = window else { return nil }
        return win.convertToScreen(convert(r, to: nil))
    }

    // Let clicks fall through to the status button so the menu opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Hover tracking

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onExit?() }

    private func report(_ event: NSEvent) {
        onHover?(target(at: convert(event.locationInWindow, from: nil)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        layoutSegments(height: h)
        let label = NSColor.labelColor
        let mid = h / 2

        if awake != .normal {
            let color: NSColor = (awake == .lidAwake) ? .systemOrange : .systemYellow
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: Self.pad, y: mid - 2, width: 4, height: 4)).fill()
        }

        if !showsAnything {
            drawIdleIcon(x: Self.pad + Self.dotWidth, h: h, label: label)
            return
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        if showNetwork { drawNetwork(in: networkRect, label: label, font: font) }
        if showsBattery, let b = battery { drawBattery(b, in: batteryRect, label: label, font: font) }
        if showsDisks { drawDisks(label: label) }
        if showEyes { drawEyes() }
    }

    private func drawEyes() {
        for (i, r) in eyeRects.enumerated() {
            let eye = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            if eyesClosed {
                NSColor(white: 0.85, alpha: 1).setFill()
                eye.fill()
                let lid = NSBezierPath()
                lid.move(to: NSPoint(x: r.minX + 1.5, y: r.midY))
                lid.curve(to: NSPoint(x: r.maxX - 1.5, y: r.midY),
                          controlPoint1: NSPoint(x: r.minX + r.width * 0.3, y: r.midY - r.height * 0.18),
                          controlPoint2: NSPoint(x: r.maxX - r.width * 0.3, y: r.midY - r.height * 0.18))
                lid.lineWidth = 1.2
                NSColor.black.setStroke()
                lid.stroke()
            } else {
                // white of the eye with a soft shade toward the bottom
                NSGradient(starting: .white, ending: NSColor(white: 0.82, alpha: 1))?.draw(in: eye, angle: -90)
                let off = i < pupilOffsets.count ? pupilOffsets[i] : .zero
                let pr = pupilRadius
                let c = NSPoint(x: r.midX + off.x, y: r.midY + off.y)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)).fill()
                NSColor.white.withAlphaComponent(0.9).setFill()
                let g = max(pr * 0.35, 0.8)
                NSBezierPath(ovalIn: NSRect(x: c.x - pr * 0.45, y: c.y + pr * 0.15, width: g, height: g)).fill()
            }
            NSColor.black.withAlphaComponent(0.85).setStroke()
            eye.lineWidth = 1
            eye.stroke()
        }
    }

    private func drawIdleIcon(x: CGFloat, h: CGFloat, label: NSColor) {
        guard let img = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "BoostBar") else { return }
        let sized = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)) ?? img
        let s = sized.size
        let tinted = NSImage(size: s, flipped: false) { r in
            sized.draw(in: r)
            label.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: x + (Self.iconWidth - s.width) / 2, y: (h - s.height) / 2, width: s.width, height: s.height))
    }

    private func drawNetwork(in r: NSRect, label: NSColor, font: NSFont) {
        let g = NSRect(x: r.minX, y: 3, width: Self.graphWidth, height: r.height - 6)
        label.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: g, xRadius: 2, yRadius: 2).fill()

        let mid = g.midY
        let half = g.height / 2 - 0.5
        let n = max(up.count, 1)
        let barW = g.width / CGFloat(n)
        let floorScale = 2_000.0   // don't amplify idle noise below ~2 KB/s
        let maxUp = max(up.max() ?? 0, floorScale)
        let maxDown = max(down.max() ?? 0, floorScale)

        upColor.setFill()
        for (i, v) in up.enumerated() where v > 0 {
            let bh = max(CGFloat(v / maxUp) * half, 0.5)
            NSBezierPath(rect: NSRect(x: g.minX + CGFloat(i) * barW, y: mid + 0.5, width: barW, height: bh)).fill()
        }
        downColor.setFill()
        for (i, v) in down.enumerated() where v > 0 {
            let bh = max(CGFloat(v / maxDown) * half, 0.5)
            NSBezierPath(rect: NSRect(x: g.minX + CGFloat(i) * barW, y: mid - 0.5 - bh, width: barW, height: bh)).fill()
        }
        label.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: NSRect(x: g.minX, y: mid - 0.5, width: g.width, height: 1)).fill()

        let tx = g.maxX + 4
        func line(_ arrow: String, _ color: NSColor, _ text: String) -> NSAttributedString {
            let s = NSMutableAttributedString(string: arrow, attributes: [.font: font, .foregroundColor: color])
            s.append(NSAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: label]))
            return s
        }
        line("▲", upColor, upText).draw(at: NSPoint(x: tx, y: mid - 0.5))
        line("▼", downColor, downText).draw(at: NSPoint(x: tx, y: mid - 11))
    }

    private func drawBattery(_ b: BatteryReading, in r: NSRect, label: NSColor, font: NSFont) {
        let mid = r.height / 2
        let top: String, bottom: String, color: NSColor
        switch b.direction {
        case .charging:    top = BatteryMonitor.formatWatts(b.watts); bottom = "IN";  color = Self.chargeColor
        case .discharging: top = BatteryMonitor.formatWatts(b.watts); bottom = "OUT"; color = Self.dischargeColor
        case .idle:
            top = b.externalConnected ? (b.systemWatts.map(BatteryMonitor.formatWatts) ?? "0.0W") : "0.0W"
            bottom = b.externalConnected ? "AC" : "IDLE"
            color = .secondaryLabelColor
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        NSAttributedString(string: top, attributes: [.font: font, .foregroundColor: label, .paragraphStyle: para])
            .draw(in: NSRect(x: r.minX, y: mid - 0.5, width: r.width, height: 11))
        NSAttributedString(string: bottom, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .bold),
                                                        .foregroundColor: color, .paragraphStyle: para])
            .draw(in: NSRect(x: r.minX, y: mid - 11, width: r.width, height: 11))
    }

    private func drawDisks(label: NSColor) {
        for (i, entry) in ledRects.enumerated() {
            let led = leds[i]
            let on = litKeys.contains(entry.key)
            let path = NSBezierPath(ovalIn: entry.rect)
            if on {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = led.color.withAlphaComponent(0.9)
                glow.shadowBlurRadius = 3
                glow.set()
                led.color.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                led.color.withAlphaComponent(0.18).setFill()
                path.fill()
                label.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 0.75
                path.stroke()
            }
        }
    }
}
