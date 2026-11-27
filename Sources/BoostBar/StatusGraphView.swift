import AppKit

/// Drawn inside the NSStatusItem button. Each segment can be turned on/off:
///  [●] [ upload ↑ | download ↓ ] ▲ 12 KB/s   8.4W   ● ●
///                                ▼ 340 KB/s   OUT   ● ●   ← disk LEDs
final class StatusGraphView: NSView {
    enum AwakeState { case normal, keepAwake, lidAwake }
    enum Target: Equatable { case network(String?), battery, disk(String), cpu, gpu }

    /// The reorderable pieces of the status item.
    enum Segment: String, CaseIterable { case eyes, network, battery, disks, cpu, gpu }
    static let defaultOrder: [Segment] = [.eyes, .network, .battery, .cpu, .gpu, .disks]

    /// Left-to-right order of the segments (drag one to change it).
    var order: [Segment] = StatusGraphView.defaultOrder
    var onClick: (() -> Void)?
    var onEyesClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onReorder: (([Segment]) -> Void)?
    private var dragging: Segment?
    var isDragging: Bool { dragging != nil }

    struct LED { let key: String; let color: NSColor }

    // Content
    var up: [Double] = []
    var down: [Double] = []
    var upText = "0.0 KB/s"
    /// One graph per connection (LAN, Wi‑Fi, …). Two or more rows → separate graphs; otherwise
    /// the single combined graph above is drawn.
    struct NetRow: Equatable { let id: String; let symbol: String; let up: [Double]; let down: [Double]; let upText: String; let downText: String }
    var netRows: [NetRow] = []
    /// TMOG-style stacked labels (NET / BAT / HDD) in front of each piece; the eyes get none.
    var verticalLabels = false
    private var labelRects: [(text: String, rect: NSRect)] = []
    static let labelWidth: CGFloat = 7
    static let labelFont = NSFont.systemFont(ofSize: 7, weight: .heavy)
    private var netRowRects: [(id: String, rect: NSRect)] = []
    private static let linkIconWidth: CGFloat = 13
    var downText = "0.0 KB/s"
    var awake: AwakeState = .normal
    /// Bloodshot eyes already say "keeping awake", so the yellow dot can go.
    var eyesShowAwake = false
    private var showsAwakeDot: Bool {
        switch awake {
        case .normal: return false
        case .keepAwake: return !(eyesShowAwake && showEyes)
        case .lidAwake: return true   // orange dot = lid-closed mode, which the eyes can't show
        }
    }
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
    var showCPU = false
    /// CPU load 0…1 (all cores together) and per core; style 0 = half-round boost gauge, 1 = a bar per core.
    var cpu: Double = 0
    var cpuCores: [Double] = []
    var cpuStyle = 0
    /// A translucent plate behind a meter so it stands out on a busy bar: level below 0 dark, above 0 light, 0 none;
    /// an optional tint colours it. The network graph, CPU meter and GPU meter each have one.
    struct Plate: Equatable { var level: Double = 0; var tint: NSColor? = nil }
    var cpuPlate = Plate(), gpuPlate = Plate(), netPlate = Plate()
    var cpuBackdrop: Double { get { cpuPlate.level } set { cpuPlate.level = newValue } }
    /// Spectrum analyzer peak markers, one per core (empty = none).
    var cpuPeaks: [Double] = []
    private(set) var cpuRect = NSRect.zero
    private static let gaugeWidth: CGFloat = 27
    /// GPU tile: recent utilization 0…1 (oldest first, one point a second) and the share of memory the GPU has in use.
    var showGPU = false
    var gpu: [Double] = []
    var gpuMemory: Double = 0
    /// 0 = history chart with a memory strip, 1 = the same half-round boost gauge as the CPU's; and the gauge's reading.
    var gpuStyle = 0
    var gpuLevel: Double = 0
    private(set) var gpuRect = NSRect.zero
    static let gpuGraphPoints = 30

    /// Disk LED size: 0 = small (two rows), 1 = medium, 2 = large
    var ledSize = 0

    // Googly eyes
    var eyeSize = 1            // 0 small, 1 medium, 2 large
    /// The mood the eyes are showing (lids, slant, pupil size, props); plain by default.
    var eyeFace = EyeFace()
    var singleEye = false
    var bloodshot = false
    var pirate = false
    /// Eyelashes: 0 none, 1 natural, 2 fake.
    var lashes = 0
    var pupilOffsets: [CGPoint] = []
    /// Set while the pupils ride the internal wheel (circle-to-spin); nil = normal.
    var wheelAngle: CGFloat?
    var eyesClosed = false

    // Hover callbacks (point is in this view's coordinates)
    var onHover: ((Target?) -> Void)?
    var onExit: (() -> Void)?

    static let chargeColor = NSColor.systemGreen
    static let dischargeColor = NSColor.systemOrange

    private static let pad: CGFloat = 3
    private static let dotWidth: CGFloat = 6
    private static let graphWidth: CGFloat = 30
    /// Room for the speed text: measured from the widest reading ("▲ 888 MB/s"), so no slack is left after it
    /// (a fixed 58 pt left a visibly bigger gap before the next piece than between the others).
    var netUnit: NetworkMonitor.Unit = .auto
    var netBits = false
    /// Network display: 0 = graph and numbers, 1 = graph only, 2 = numbers only.
    var netDisplay = 0
    private var netShowsGraph: Bool { netDisplay != 2 }
    private var netShowsText: Bool { netDisplay != 1 }
    /// Width of one network block: the graph, the numbers, or both with a gap between.
    private var netBlockWidth: CGFloat {
        (netShowsGraph ? Self.graphWidth : 0) + (netShowsGraph && netShowsText ? 4 : 0) + (netShowsText ? netTextWidth : 0)
    }
    /// Room for the speed text: measured from the widest typical reading in the chosen unit, so no slack is left.
    private var netTextWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let u = netBits ? "b/s" : "B/s"
        let samples: [String]
        switch netUnit {
        case .auto, .kilo: samples = ["888 K\(u)"]
        case .mega: samples = ["88.88 M\(u)"]
        }
        let w = samples.flatMap { ["▲ " + $0, "▼ " + $0] }.map {
            NSAttributedString(string: $0, attributes: [.font: font]).size().width
        }.max() ?? 50
        return ceil(w)
    }
    /// Just wide enough for the widest watts reading, so no slack pads either side of it.
    private static let batteryWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let w = ["88.8W", "188W"].map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 26
        let l = NSAttributedString(string: "IDLE", attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .heavy)]).size().width
        return ceil(max(w, l)) + 1
    }()
    private static let iconWidth: CGFloat = 20
    private static let ledDiameters: [CGFloat] = [7, 11, 15]
    private static let eyeSizes: [NSSize] = [NSSize(width: 9, height: 13), NSSize(width: 12, height: 17), NSSize(width: 15, height: 20)]

    private var showsBattery: Bool { showBattery && battery != nil }
    private var showsDisks: Bool { showDisks && !leds.isEmpty }
    private var showsAnything: Bool { showNetwork || showsBattery || showsDisks || showEyes || showCPU || showGPU }

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
        if showsAwakeDot || !showsAnything { x += Self.dotWidth }
        netRowRects = []
        labelRects = []
        networkRect = .zero; batteryRect = .zero; diskRect = .zero; eyesRect = .zero; ledRects = []; eyeRects = []
        cpuRect = .zero; gpuRect = .zero
        if !showsAnything { return x + Self.iconWidth + Self.pad }

        var first = true
        var prev: Segment?
        func gap(_ w: CGFloat = 4) { if !first { x += w }; first = false }
        func label(_ text: String) {
            guard verticalLabels else { return }
            labelRects.append((text, NSRect(x: x, y: 0, width: Self.labelWidth, height: h)))
            x += Self.labelWidth + 2
        }

        for seg in order {
            let before = x
            defer { if x != before { prev = seg } }
            switch seg {
            case .eyes:
                if showEyes {
                    gap()
                    let e = eyeDims
                    // lashes need a little room: beside the outer corners, and above (the eyes sit a touch lower and shorter)
                    let lp: CGFloat = lashes == 0 ? 0 : ceil(e.width * (lashes == 2 ? 0.36 : 0.2))
                    let lv: CGFloat = lashes == 0 ? 0 : (lashes == 2 ? 3 : 2)
                    let eh = min(e.height, h - 2 - lv)
                    let count = singleEye ? 1 : 2
                    for i in 0..<count {
                        eyeRects.append(NSRect(x: x + lp + CGFloat(i) * (e.width + 1), y: (h - eh) / 2 - lv / 2, width: e.width, height: eh))
                    }
                    eyesRect = NSRect(x: x, y: 0, width: CGFloat(count) * e.width + CGFloat(count - 1) + lp * 2, height: h)
                    x = eyesRect.maxX
                }
            case .network:
                if showNetwork {
                    gap()
                    label("NET")
                    if netRows.count >= 2 {
                        let start = x
                        for (i, row) in netRows.enumerated() {
                            if i > 0 { x += 5 }
                            let r = NSRect(x: x, y: 0, width: Self.linkIconWidth + netBlockWidth, height: h)
                            netRowRects.append((row.id, r))
                            x = r.maxX
                        }
                        networkRect = NSRect(x: start, y: 0, width: x - start, height: h)
                    } else {
                        networkRect = NSRect(x: x, y: 0, width: netBlockWidth, height: h)
                        x = networkRect.maxX
                    }
                }
            case .battery:
                if showsBattery {
                    gap(3)
                    label("BAT")
                    batteryRect = NSRect(x: x, y: 0, width: batteryTextWidth, height: h)
                    x = batteryRect.maxX
                }
            case .cpu:
                if showCPU {
                    gap(prev == .disks ? 6 : 4)    // a little air between an LED and the gauge's rim
                    label("CPU")
                    let n = max(cpuCores.count, 1)
                    let w = cpuStyle == 1 ? CGFloat(n) * Self.cpuBarPitch(n) + 1 : Self.gaugeWidth
                    cpuRect = NSRect(x: x, y: 0, width: w, height: h)
                    x = cpuRect.maxX
                }
            case .gpu:
                if showGPU {
                    gap(prev == .disks ? 6 : 5)
                    label("GPU")
                    gpuRect = NSRect(x: x, y: 0, width: gpuStyle == 1 ? Self.gaugeWidth : gpuChartWidth, height: h)
                    x = gpuRect.maxX
                }
            case .disks:
                if showsDisks {
                    gap(prev == .cpu || prev == .gpu ? 6 : 2)
                    label("HDD")
                    // Small LEDs stack in two rows when there are several drives; medium/large use one row.
                    let dia = Self.ledDiameters[min(max(ledSize, 0), 2)]
                    let cell = dia + 2
                    let rows = (ledSize == 0 && leds.count > 1) ? 2 : 1
                    let cols = Int(ceil(Double(leds.count) / Double(rows)))
                    diskRect = NSRect(x: x, y: 0, width: CGFloat(cols) * cell, height: h)
                    for (i, led) in leds.enumerated() {
                        let col = i / rows, row = i % rows
                        let cy: CGFloat = rows == 1 ? h / 2 : (row == 0 ? h / 2 + 4.5 : h / 2 - 4.5)
                        let rect = NSRect(x: x + CGFloat(col) * cell + 0.5, y: cy - dia / 2, width: dia, height: dia)
                        ledRects.append((led.key, rect))
                    }
                    x = diskRect.maxX
                }
            }
        }
        return x + Self.pad
    }

    func target(at p: NSPoint) -> Target? {
        if networkRect.insetBy(dx: -2, dy: 0).contains(p) {
            if let row = netRowRects.first(where: { $0.rect.insetBy(dx: -3, dy: 0).contains(p) }) { return .network(row.id) }
            return .network(nil)
        }
        if batteryRect.insetBy(dx: -2, dy: 0).contains(p) { return .battery }
        if cpuRect.insetBy(dx: -2, dy: 0).contains(p) { return .cpu }
        if gpuRect.insetBy(dx: -2, dy: 0).contains(p) { return .gpu }
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
        case .network(let id): r = netRowRects.first(where: { $0.id == id })?.rect ?? networkRect
        case .battery: r = batteryRect
        case .cpu: r = cpuRect
        case .gpu: r = gpuRect
        case .disk(let k): r = ledRects.first(where: { $0.key == k })?.rect.insetBy(dx: -4, dy: -8) ?? diskRect
        }
        guard !r.isEmpty, let win = window else { return nil }
        return win.convertToScreen(convert(r, to: nil))
    }

    func rect(of seg: Segment) -> NSRect {
        switch seg {
        case .eyes: return eyesRect
        case .network: return networkRect
        case .battery: return batteryRect
        case .disks: return diskRect
        case .cpu: return cpuRect
        case .gpu: return gpuRect
        }
    }

    func segment(at p: NSPoint) -> Segment? {
        order.first { !rect(of: $0).isEmpty && rect(of: $0).insetBy(dx: -2, dy: 0).contains(p) }
    }

    // MARK: Click to open the menu, drag a segment to reorder

    // Clicks are routed here by the app's event monitor (see AppDelegate), so the status
    // button never swallows them. Hover tracking areas still work with hitTest = nil.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Runs a click-or-drag tracking loop starting from a mouse-down in this view's window.
    func trackMouse(from event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let clicked = segment(at: start)
        let click = { [weak self] in
            if clicked == .eyes, let open = self?.onEyesClick { open() } else { self?.onClick?() }
        }
        guard let seg = clicked, visibleSegmentCount > 1 else { click(); return }

        var didDrag = false
        while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                      inMode: .eventTracking, dequeue: true) {
            if e.type == .leftMouseUp { break }
            let p = convert(e.locationInWindow, from: nil)
            if !didDrag, abs(p.x - start.x) > 3 {
                didDrag = true
                dragging = seg
                onDragBegan?()
                NSCursor.closedHand.push()
            }
            guard didDrag else { continue }

            // Place the dragged piece by the pointer: count how many other visible pieces
            // have their middle to the left of the pointer.
            let visible = order.filter { !rect(of: $0).isEmpty }
            let others = visible.filter { $0 != seg }
            let index = others.filter { rect(of: $0).midX < p.x }.count
            var newVisible = others
            newVisible.insert(seg, at: index)
            let hidden = order.filter { !visible.contains($0) }
            let newOrder = newVisible + hidden
            if newOrder != order {
                order = newOrder
                layoutSegments(height: bounds.height)
            }
            display()   // the tracking loop blocks normal redraws
        }

        if didDrag {
            NSCursor.pop()
            dragging = nil
            display()
            onReorder?(order)
        } else {
            click()
        }
    }

    private var visibleSegmentCount: Int { order.filter { !rect(of: $0).isEmpty }.count }

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

        if showsAwakeDot {
            let color: NSColor = (awake == .lidAwake) ? .systemOrange : .systemYellow
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: Self.pad, y: mid - 2, width: 4, height: 4)).fill()
        }

        if !showsAnything {
            drawIdleIcon(x: Self.pad + Self.dotWidth, h: h, label: label)
            return
        }

        if let d = dragging {
            let r = rect(of: d).insetBy(dx: -2, dy: 1)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        for (text, r) in labelRects { drawVerticalLabel(text, in: r, color: label) }
        if showCPU, !cpuRect.isEmpty {
            if cpuStyle == 1 { drawCPUBars(in: cpuRect, label: label) } else { drawGauge(in: cpuRect, value: cpu, plate: cpuPlate) }
        }
        if showGPU, !gpuRect.isEmpty {
            if gpuStyle == 1 { drawGauge(in: gpuRect, value: gpuLevel, plate: gpuPlate) } else { drawGPUChart(in: gpuRect) }
        }
        if showNetwork {
            if netRowRects.isEmpty {
                drawNetwork(in: networkRect, up: up, down: down, upText: upText, downText: downText, label: label, font: font)
            } else {
                for (row, r) in zip(netRows, netRowRects.map(\.rect)) {
                    if let img = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
                        ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil) {
                        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                        let sym = img.withSymbolConfiguration(cfg) ?? img
                        let tinted = NSImage(size: sym.size, flipped: false) { rect in
                            sym.draw(in: rect)
                            label.withAlphaComponent(0.85).set()
                            rect.fill(using: .sourceAtop)
                            return true
                        }
                        let sz = sym.size
                        tinted.draw(in: NSRect(x: r.minX + (Self.linkIconWidth - 2 - sz.width) / 2, y: (r.height - sz.height) / 2,
                                               width: sz.width, height: sz.height))
                    }
                    var g = r
                    g.origin.x += Self.linkIconWidth
                    g.size.width -= Self.linkIconWidth
                    drawNetwork(in: g, up: row.up, down: row.down, upText: row.upText, downText: row.downText, label: label, font: font)
                }
            }
        }
        if showsBattery, let b = battery { drawBattery(b, in: batteryRect, label: label, font: font) }
        if showsDisks { drawDisks(label: label) }
        if showEyes { drawEyes(); drawLashes(); drawEyepatch() }
    }

    private func drawEyes() {
        let patched = pirate && eyeRects.count > 1 ? 0 : -1   // pirate: patch over the left eye
        let face = eyeFace
        for (i, r0) in eyeRects.enumerated() {
            if i == patched { continue }
            let r = r0.offsetBy(dx: 0, dy: min(face.lift, bounds.height - r0.maxY))
            let eye = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            if face.smile && !eyesClosed {
                // happy: closed, arched eyes
                NSGradient(starting: .white, ending: NSColor(white: 0.86, alpha: 1))?.draw(in: eye, angle: -90)
                let arc = NSBezierPath()
                arc.move(to: NSPoint(x: r.minX + 2, y: r.midY - r.height * 0.08))
                arc.curve(to: NSPoint(x: r.maxX - 2, y: r.midY - r.height * 0.08),
                          controlPoint1: NSPoint(x: r.minX + r.width * 0.3, y: r.midY + r.height * 0.3),
                          controlPoint2: NSPoint(x: r.maxX - r.width * 0.3, y: r.midY + r.height * 0.3))
                arc.lineWidth = max(1.4, r.width * 0.13)
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            } else if eyesClosed {
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
                // white of the eye with a soft shade toward the bottom (pinkish when bloodshot)
                if bloodshot {
                    NSGradient(starting: NSColor(srgbRed: 1, green: 0.95, blue: 0.94, alpha: 1),
                               ending: NSColor(srgbRed: 0.98, green: 0.72, blue: 0.72, alpha: 1))?.draw(in: eye, angle: -90)
                    drawVeins(in: r, clip: eye, seed: i)
                } else {
                    NSGradient(starting: .white, ending: NSColor(white: 0.82, alpha: 1))?.draw(in: eye, angle: -90)
                }
                let pr = pupilRadius * face.pupilScale
                func pupil(at c: NSPoint, squash: CGFloat = 1) {
                    if face.symbol == 1 {
                        // a heart
                        let s = pr * 1.25
                        let h = NSBezierPath()
                        h.move(to: NSPoint(x: c.x, y: c.y - s))
                        h.curve(to: NSPoint(x: c.x - s, y: c.y + s * 0.25), controlPoint1: NSPoint(x: c.x - s * 0.5, y: c.y - s * 0.55), controlPoint2: NSPoint(x: c.x - s, y: c.y - s * 0.15))
                        h.curve(to: NSPoint(x: c.x, y: c.y + s * 0.45), controlPoint1: NSPoint(x: c.x - s, y: c.y + s * 0.95), controlPoint2: NSPoint(x: c.x - s * 0.15, y: c.y + s * 0.95))
                        h.curve(to: NSPoint(x: c.x + s, y: c.y + s * 0.25), controlPoint1: NSPoint(x: c.x + s * 0.15, y: c.y + s * 0.95), controlPoint2: NSPoint(x: c.x + s, y: c.y + s * 0.95))
                        h.curve(to: NSPoint(x: c.x, y: c.y - s), controlPoint1: NSPoint(x: c.x + s, y: c.y - s * 0.15), controlPoint2: NSPoint(x: c.x + s * 0.5, y: c.y - s * 0.55))
                        NSColor(srgbRed: 0.93, green: 0.11, blue: 0.24, alpha: 1).setFill()
                        h.fill()
                        return
                    }
                    if face.symbol == 2 {
                        let f = NSFont.systemFont(ofSize: pr * 3.2, weight: .heavy)
                        let t = NSAttributedString(string: "$", attributes: [.font: f, .foregroundColor: NSColor(srgbRed: 0.1, green: 0.55, blue: 0.16, alpha: 1)])
                        let sz = t.size()
                        t.draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
                        return
                    }
                    let w = pr * 2 * squash
                    NSColor.black.setFill()
                    NSBezierPath(ovalIn: NSRect(x: c.x - w / 2, y: c.y - pr, width: w, height: pr * 2)).fill()
                    NSColor.white.withAlphaComponent(0.9 * squash).setFill()
                    let g = max(pr * 0.35, 0.8)
                    NSBezierPath(ovalIn: NSRect(x: c.x - pr * 0.45 * squash, y: c.y + pr * 0.15, width: g * squash, height: g)).fill()
                }
                if let wheel = wheelAngle {
                    // four pupils on a wheel turning about a vertical axis through the middle of both eyes: the ones
                    // on the near side show through the whites and slide from one eye into the other
                    NSGraphicsContext.saveGraphicsState()
                    eye.addClip()
                    let span = eyesRect.width / 2 + 1
                    for k in 0..<4 {
                        let a = wheel + CGFloat(k) * .pi / 2
                        let depth = cos(a)
                        guard depth > 0 else { continue }      // round the back of the wheel
                        let x = eyesRect.midX + span * sin(a)
                        pupil(at: NSPoint(x: x, y: r.midY - pr * 0.15), squash: max(0.35, depth))
                    }
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    let off = i < pupilOffsets.count ? pupilOffsets[i] : .zero
                    pupil(at: face.symbol != 0 ? NSPoint(x: r.midX, y: r.midY) : NSPoint(x: r.midX + off.x, y: r.midY + off.y))
                }
                // a one-eye squint (skeptical) closes this eye's lids further than the mood's own
                let sq: CGFloat = eyeRects.count > 1 ? (i == 0 ? face.squintL : face.squintR) : max(face.squintL, face.squintR)
                let lt = max(face.lidTop, sq * 0.62), lb = max(face.lidBottom, sq * 0.42)
                if lt > 0.01 || lb > 0.01 {
                    // lids: the upper one can slant (toward the middle when angry, toward the outside when sad)
                    NSGraphicsContext.saveGraphicsState()
                    eye.addClip()
                    let lidFill = NSColor(white: bloodshot ? 0.74 : 0.78, alpha: 1)
                    if lt > 0.01 {
                        // which side of this eye faces the other eye
                        let innerIsRight = eyeRects.count > 1 ? i == 0 : true
                        let slant = eyeRects.count > 1 ? face.slant : 0
                        let inner = max(0, lt + slant), outer = max(0, lt - slant * 0.6)
                        let yL = r.maxY - r.height * (innerIsRight ? outer : inner)
                        let yR = r.maxY - r.height * (innerIsRight ? inner : outer)
                        let lid = NSBezierPath()
                        lid.move(to: NSPoint(x: r.minX, y: r.maxY + 1)); lid.line(to: NSPoint(x: r.maxX, y: r.maxY + 1))
                        lid.line(to: NSPoint(x: r.maxX, y: yR)); lid.line(to: NSPoint(x: r.minX, y: yL)); lid.close()
                        lidFill.setFill(); lid.fill()
                        let edge = NSBezierPath()
                        edge.move(to: NSPoint(x: r.minX, y: yL)); edge.line(to: NSPoint(x: r.maxX, y: yR))
                        edge.lineWidth = abs(slant) > 0.05 ? 1.5 : 1
                        NSColor.black.setStroke(); edge.stroke()
                    }
                    if lb > 0.01 {
                        let y = r.minY + r.height * lb
                        lidFill.setFill()
                        NSBezierPath(rect: NSRect(x: r.minX, y: r.minY - 1, width: r.width, height: y - r.minY + 1)).fill()
                        let edge = NSBezierPath()
                        edge.move(to: NSPoint(x: r.minX, y: y)); edge.line(to: NSPoint(x: r.maxX, y: y))
                        edge.lineWidth = 1
                        NSColor.black.setStroke(); edge.stroke()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            (bloodshot && !eyesClosed ? NSColor(srgbRed: 0.6, green: 0.05, blue: 0.08, alpha: 1)
                                      : NSColor.black.withAlphaComponent(0.85)).setStroke()
            eye.lineWidth = 1
            eye.stroke()
        }
        if face.sweat >= 0, let r = eyeRects.last {
            // a sweat drop sliding down beside the eye
            let w = max(2.6, r.width * 0.26), hgt = w * 1.5
            let x = r.maxX - w * 0.55, y = r.maxY - hgt * 0.6 - face.sweat * r.height * 0.45
            let d = NSBezierPath()
            d.move(to: NSPoint(x: x + w / 2, y: y + hgt))
            d.curve(to: NSPoint(x: x + w / 2, y: y), controlPoint1: NSPoint(x: x + w * 1.25, y: y + hgt * 0.35), controlPoint2: NSPoint(x: x + w, y: y))
            d.curve(to: NSPoint(x: x + w / 2, y: y + hgt), controlPoint1: NSPoint(x: x, y: y), controlPoint2: NSPoint(x: x - w * 0.25, y: y + hgt * 0.35))
            NSColor(srgbRed: 0.35, green: 0.72, blue: 1, alpha: CGFloat(1 - max(0, face.sweat - 0.7) / 0.3)).setFill()
            d.fill()
            NSColor(srgbRed: 0.1, green: 0.35, blue: 0.75, alpha: 0.8).setStroke()
            d.lineWidth = 0.5
            d.stroke()
        }
    }

    /// Eyelashes fanning off each eye's outer corner. They ride on the upper lid: lower with a drooping lid, sweep
    /// down on a blink. Natural is three short ones; fake is five long curled ones on a heavier liner.
    private func drawLashes() {
        guard lashes > 0 else { return }
        let fake = lashes == 2
        let patched = pirate && eyeRects.count > 1 ? 0 : -1
        let face = eyeFace
        NSColor.labelColor.setStroke()
        for (i, r0) in eyeRects.enumerated() {
            if i == patched { continue }
            let r = r0.offsetBy(dx: 0, dy: min(face.lift, bounds.height - r0.maxY))
            let rx = Double(r.width) / 2 - 0.5, ry = Double(r.height) / 2 - 0.5
            let cx = Double(r.midX), cy = Double(r.midY)
            let sides: [Double] = eyeRects.count > 1 ? [i == 0 ? -1 : 1] : [-1, 1]
            let sq = Double(eyeRects.count > 1 ? (i == 0 ? face.squintL : face.squintR) : max(face.squintL, face.squintR))
            let top = max(Double(face.lidTop), sq * 0.62)
            let slant = eyeRects.count > 1 ? Double(face.slant) : 0
            let lid = top > 0.01 ? max(0, top - slant * 0.6) : 0        // how far the lid is down at the outer corner
            // where the lashes root, in degrees round the rim from the top toward the outer side
            var lo: Double, hi: Double, curl: Double, tilt = 0.0
            var n = fake ? 5 : 3, liner = fake
            if eyesClosed { lo = 100; hi = 142; curl = -0.4; n = 3; liner = false }
            else if face.smile { lo = 72; hi = 104; curl = 0.35; n = 3; liner = false }
            else if lid > 0.02 {
                let tc = Foundation.acos(max(-0.99, min(0.99, 1 - 2 * lid))) * 180 / Double.pi
                // they stay put until the lid comes down to them, then ride it
                hi = max(tc, fake ? 90 : 80); lo = hi - (fake ? 64 : 40); curl = fake ? 0.45 : 0.4; tilt = -30 * lid
            } else { lo = fake ? 26 : 40; hi = fake ? 90 : 80; curl = fake ? 0.45 : 0.4 }
            let length = rx * (fake ? 0.8 : 0.42)
            for side in sides {
                func rim(_ deg: Double, _ k: Double = 1) -> NSPoint {
                    let a = deg * Double.pi / 180
                    return NSPoint(x: cx + side * Foundation.sin(a) * rx * k, y: cy + Foundation.cos(a) * ry * k)
                }
                if liner {
                    let p = NSBezierPath()
                    for s in 0...12 {
                        let pt = rim(lo - 8 + (hi - lo + 12) * Double(s) / 12, 1.04)
                        if s == 0 { p.move(to: pt) } else { p.line(to: pt) }
                    }
                    p.lineWidth = CGFloat(max(1.0, rx * 0.15)); p.lineCapStyle = .round; p.lineJoinStyle = .round
                    p.stroke()
                }
                for k in 0..<n {
                    let deg = lo + (hi - lo) * Double(k) / Double(n - 1)
                    let root = rim(deg)
                    let dir = (90 - deg + tilt) * Double.pi / 180
                    let p = NSBezierPath()
                    p.move(to: root)
                    for s in 1...8 {
                        let t = Double(s) / 8, a = dir + curl * t
                        p.line(to: NSPoint(x: Double(root.x) + side * Foundation.cos(a) * length * t, y: Double(root.y) + Foundation.sin(a) * length * t))
                    }
                    p.lineWidth = CGFloat(fake ? max(0.9, rx * 0.16) : max(0.7, rx * 0.11))
                    p.lineCapStyle = .round; p.lineJoinStyle = .round
                    p.stroke()
                }
            }
        }
    }

    /// Black eyepatch over the left eye, with its strap running up and across.
    private func drawEyepatch() {
        guard pirate, eyeRects.count > 1 else { return }
        let r = eyeRects[0]
        let other = eyeRects[eyeRects.count - 1]
        let strap = NSBezierPath()
        // strap: from the far left edge, over the patch, and up past the other eye
        strap.move(to: NSPoint(x: r.minX - 2, y: r.minY + r.height * 0.15))
        strap.line(to: NSPoint(x: r.midX, y: r.midY))
        strap.curve(to: NSPoint(x: other.maxX + 2, y: other.maxY + 1),
                    controlPoint1: NSPoint(x: r.maxX + 1, y: r.maxY - 1),
                    controlPoint2: NSPoint(x: other.midX, y: other.maxY + 1))
        strap.lineWidth = max(1, r.width * 0.1)
        strap.lineCapStyle = .round
        NSColor.black.setStroke()
        strap.stroke()

        let patch = NSBezierPath(ovalIn: r.insetBy(dx: -0.5, dy: r.height * 0.06))
        NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.02, alpha: 1))?.draw(in: patch, angle: -90)
        NSColor(white: 0.55, alpha: 0.6).setStroke()
        patch.lineWidth = 0.6
        patch.stroke()
    }

    /// Thin red veins creeping in from the rim toward the iris.
    private func drawVeins(in r: NSRect, clip: NSBezierPath, seed: Int) {
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let red = NSColor(srgbRed: 0.85, green: 0.07, blue: 0.10, alpha: 0.85)
        red.setStroke()
        // Fixed angles per eye so the veins don't flicker between frames.
        let angles: [CGFloat] = seed % 2 == 0 ? [0.25, 1.9, 3.3, 4.6, 5.6] : [0.9, 2.6, 3.9, 5.0, 6.0]
        let c = NSPoint(x: r.midX, y: r.midY)
        for (k, a) in angles.enumerated() {
            let edge = NSPoint(x: c.x + cos(a) * r.width / 2, y: c.y + sin(a) * r.height / 2)
            let inner = NSPoint(x: c.x + cos(a) * r.width * 0.17, y: c.y + sin(a) * r.height * 0.17)
            let wiggle: CGFloat = (k % 2 == 0 ? 1 : -1) * r.width * 0.12
            let v = NSBezierPath()
            v.move(to: edge)
            v.curve(to: inner,
                    controlPoint1: NSPoint(x: (edge.x * 2 + inner.x) / 3 - sin(a) * wiggle, y: (edge.y * 2 + inner.y) / 3 + cos(a) * wiggle),
                    controlPoint2: NSPoint(x: (edge.x + inner.x * 2) / 3 + sin(a) * wiggle, y: (edge.y + inner.y * 2) / 3 - cos(a) * wiggle))
            v.lineWidth = 0.6
            v.stroke()
            // a small fork on alternate veins
            if k % 2 == 0 {
                let mid = NSPoint(x: (edge.x + inner.x) / 2, y: (edge.y + inner.y) / 2)
                let f = NSBezierPath()
                f.move(to: mid)
                f.line(to: NSPoint(x: mid.x + cos(a + 0.9) * r.width * 0.14, y: mid.y + sin(a + 0.9) * r.height * 0.14))
                f.lineWidth = 0.45
                f.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
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

    /// The battery readout is exactly as wide as what it shows right now ("8.4W" over "OUT", "42W" over "IN", …).
    private var batteryTextWidth: CGFloat {
        guard let b = battery else { return Self.batteryWidth }
        let top = b.direction == .idle ? (b.externalConnected ? (b.systemWatts.map(BatteryMonitor.formatWatts) ?? "0.0W") : "0.0W")
                                       : BatteryMonitor.formatWatts(b.watts)
        let bottom = b.direction == .charging ? "IN" : b.direction == .discharging ? "OUT" : (b.externalConnected ? "AC" : "IDLE")
        let f = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let w = max(NSAttributedString(string: top, attributes: [.font: f]).size().width,
                    NSAttributedString(string: bottom, attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .heavy)]).size().width)
        return ceil(w) + 1
    }

    // MARK: CPU

    private static func cpuBarPitch(_ cores: Int) -> CGFloat { cores > 12 ? 2 : cores > 8 ? 3 : 4 }

    /// Is the menu bar light (dark text) right now? It follows the wallpaper, not just Light/Dark mode.
    private var barIsLight: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua }
    /// What a meter is drawn against: the bar, or its plate once that is strong enough to take over.
    private func onLight(_ p: Plate) -> Bool { p.level > 0.35 ? true : p.level < -0.35 ? false : barIsLight }
    private func ink(_ p: Plate) -> NSColor {
        let light = onLight(p)
        return light == barIsLight ? .labelColor : (light ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.95, alpha: 1))
    }

    /// Boost-gauge colours: green, lime, yellow, orange, red — as on the X1 sim's loading gauge. On a light
    /// background they're deepened so the yellow and lime still read against white.
    private func boostColor(_ x: Double, onLight: Bool) -> NSColor {
        let stops: [(Double, [Double])] = [(0, [62, 220, 64]), (0.28, [196, 236, 34]), (0.45, [250, 214, 20]),
                                           (0.66, [250, 128, 22]), (0.82, [236, 34, 40]), (1, [236, 30, 42])]
        var i = 1
        while i < stops.count - 1 && stops[i].0 < x { i += 1 }
        let (a, ca) = stops[i - 1], (b, cb) = stops[i]
        let k = min(1, max(0, (x - a) / (b - a)))
        var c = (0..<3).map { (ca[$0] + (cb[$0] - ca[$0]) * k) / 255 }
        if onLight { c = [c[0] * 0.80, c[1] * 0.66, c[2] * 0.62] }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    /// The plate's colour: black or white at the slider's strength, or — with a tint — that colour deepened on the
    /// dark side and paled on the light side, so whatever is picked the meter on it stays readable.
    private func plateColor(_ p: Plate) -> NSColor {
        let dark = p.level < 0, strength = CGFloat(min(1, abs(p.level)))
        guard let tint = p.tint?.usingColorSpace(.sRGB) else {
            return (dark ? NSColor.black : NSColor.white).withAlphaComponent(strength * 0.7)
        }
        let mixed = tint.blended(withFraction: dark ? 0.5 : 0.7, of: dark ? .black : .white) ?? tint
        return mixed.withAlphaComponent(min(1, strength * 0.7 + 0.2))
    }

    /// The rounded plate every chart-style meter sits on (network graph, CPU bars, GPU chart).
    private func fillPlate(_ p: Plate, around g: NSRect) {
        guard p.level != 0 else { return }
        plateColor(p).setFill()
        NSBezierPath(roundedRect: g.insetBy(dx: -1.5, dy: -1.5), xRadius: 3, yRadius: 3).fill()
    }

    /// The tiny half-round boost gauge: a crescent that thickens toward full boost, cut by gaps, lit up to the
    /// needle and dim beyond it; the needle and hub take the menu bar's text colour.
    private func drawGauge(in r: NSRect, value: Double, plate: Plate) {
        let x = min(1, max(0, value))
        let light = onLight(plate), meterInk = ink(plate)
        let c = NSPoint(x: r.midX, y: r.midY - 5.5)
        let R = min(r.width / 2 - 0.5, r.height - 8)
        if plate.level != 0 {
            // a dome: round over the top of the dial, with a short rounded foot under the needle's hub
            let pr = R + 1.6, foot: CGFloat = 3.4
            let dome = NSBezierPath()
            dome.move(to: NSPoint(x: c.x - pr, y: c.y))
            dome.appendArc(withCenter: c, radius: pr, startAngle: 180, endAngle: 0, clockwise: true)
            dome.line(to: NSPoint(x: c.x + pr, y: c.y - foot + 2))
            dome.appendArc(withCenter: NSPoint(x: c.x + pr - 2, y: c.y - foot + 2), radius: 2, startAngle: 0, endAngle: 270, clockwise: true)
            dome.line(to: NSPoint(x: c.x - pr + 2, y: c.y - foot))
            dome.appendArc(withCenter: NSPoint(x: c.x - pr + 2, y: c.y - foot + 2), radius: 2, startAngle: 270, endAngle: 180, clockwise: true)
            dome.close()
            plateColor(plate).setFill()
            dome.fill()
        }
        // from 9 o'clock over the top to 3 o'clock
        func ang(_ t: Double) -> CGFloat { CGFloat(180 - 180 * t) }
        let gaps = [0.16, 0.36, 0.56, 0.74, 0.88]
        let n = 60
        for i in 0..<n {
            let t0 = Double(i) / Double(n), t1 = Double(i + 1) / Double(n), tm = (t0 + t1) / 2
            if gaps.contains(where: { abs(tm - $0) < 0.02 }) { continue }
            let w = 1.6 + 3.4 * CGFloat(pow(tm, 1.35))
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: R, startAngle: ang(t0), endAngle: ang(t1) - 0.6, clockwise: true)
            p.appendArc(withCenter: c, radius: R - w, startAngle: ang(t1) - 0.6, endAngle: ang(t0), clockwise: false)
            p.close()
            if tm <= x + 0.002 { boostColor(tm, onLight: light).setFill() } else { meterInk.withAlphaComponent(light ? 0.2 : 0.24).setFill() }
            p.fill()
        }
        // needle
        let a = ang(x) * .pi / 180
        let len = R - 1.5
        let tip = NSPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len)
        let side = NSPoint(x: -sin(a) * 1.1, y: cos(a) * 1.1)
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: c.x + side.x, y: c.y + side.y))
        needle.line(to: tip)
        needle.line(to: NSPoint(x: c.x - side.x, y: c.y - side.y))
        needle.close()
        meterInk.setFill()
        needle.fill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6)).fill()
    }

    /// One slim vertical bar per core, like TMOG's CPU meter.
    private func drawCPUBars(in r: NSRect, label: NSColor) {
        let cores = cpuCores.isEmpty ? [cpu] : cpuCores
        let pitch = Self.cpuBarPitch(cores.count)
        let light = onLight(cpuPlate), meterInk = ink(cpuPlate)
        let g = NSRect(x: r.minX, y: 3, width: r.width, height: r.height - 6)
        fillPlate(cpuPlate, around: g)
        for (i, v) in cores.enumerated() {
            let slot = NSRect(x: g.minX + CGFloat(i) * pitch + 0.5, y: g.minY, width: pitch - 1, height: g.height)
            meterInk.withAlphaComponent(0.14).setFill()
            NSBezierPath(rect: slot).fill()
            let hgt = max(1, slot.height * CGFloat(min(1, max(0, v))))
            boostColor(v, onLight: light).setFill()
            NSBezierPath(rect: NSRect(x: slot.minX, y: slot.minY, width: slot.width, height: hgt)).fill()
            if i < cpuPeaks.count, cpuPeaks[i] > v + 0.03 {
                // the peak-hold cap: a thin line left at the top of the last surge
                let py = slot.minY + slot.height * CGFloat(min(1, cpuPeaks[i]))
                meterInk.withAlphaComponent(0.9).setFill()
                NSBezierPath(rect: NSRect(x: slot.minX, y: min(slot.maxY, py) - 1, width: slot.width, height: 1)).fill()
            }
        }
    }

    // MARK: GPU

    /// Amber for the GPU's load, teal for its memory — deepened on a light background, like the boost colours.
    static let gpuColor = NSColor(srgbRed: 0.98, green: 0.70, blue: 0.16, alpha: 1)
    static let gpuMemoryColor = NSColor(srgbRed: 0.36, green: 0.79, blue: 0.65, alpha: 1)

    /// As wide as the CPU's spectrum analyzer on this Mac, so the two plates match.
    private var gpuChartWidth: CGFloat {
        let n = cpuCores.isEmpty ? ProcessInfo.processInfo.activeProcessorCount : cpuCores.count
        return max(24, CGFloat(n) * Self.cpuBarPitch(n) + 1)
    }

    /// The CPU meter's twin: a scrolling chart of the last half minute of GPU load, and — one bar's gap to its
    /// right, the same spacing as the CPU's bars — a slim strip that fills with the memory the GPU has in use.
    private func drawGPUChart(in r: NSRect) {
        let light = onLight(gpuPlate), meterInk = ink(gpuPlate)
        let gpuInk = light ? NSColor(srgbRed: 0.76, green: 0.45, blue: 0.04, alpha: 1) : Self.gpuColor
        let memInk = light ? NSColor(srgbRed: 0.06, green: 0.50, blue: 0.40, alpha: 1) : Self.gpuMemoryColor
        let g = NSRect(x: r.minX, y: 3, width: r.width, height: r.height - 6)
        fillPlate(gpuPlate, around: g)
        let n = cpuCores.isEmpty ? ProcessInfo.processInfo.activeProcessorCount : cpuCores.count
        let stripW = max(2, Self.cpuBarPitch(n) - 1)
        let right = g.maxX - 1.5                                    // where the CPU's last bar ends
        let strip = NSRect(x: right - stripW, y: g.minY, width: stripW, height: g.height)
        let chart = NSRect(x: g.minX + 0.5, y: g.minY, width: strip.minX - 1 - (g.minX + 0.5), height: g.height)
        meterInk.withAlphaComponent(0.14).setFill()
        NSBezierPath(rect: chart).fill()
        NSBezierPath(rect: strip).fill()
        let count = Self.gpuGraphPoints
        var vals = Array(gpu.suffix(count))
        if vals.count < count { vals = Array(repeating: 0, count: count - vals.count) + vals }
        let step = chart.width / CGFloat(count - 1)
        let pts = vals.enumerated().map { i, v in
            NSPoint(x: chart.minX + CGFloat(i) * step, y: chart.minY + (chart.height - 1) * CGFloat(min(1, max(0, v))) + 0.5)
        }
        let area = NSBezierPath()
        area.move(to: NSPoint(x: chart.minX, y: chart.minY))
        pts.forEach { area.line(to: $0) }
        area.line(to: NSPoint(x: chart.maxX, y: chart.minY))
        area.close()
        gpuInk.withAlphaComponent(0.45).setFill()
        area.fill()
        let line = NSBezierPath()
        line.move(to: pts[0])
        pts.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 1
        line.lineJoinStyle = .round
        gpuInk.setStroke()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: chart).addClip()
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let m = CGFloat(min(1, max(0, gpuMemory)))
        if m > 0 {
            memInk.setFill()
            NSBezierPath(rect: NSRect(x: strip.minX, y: strip.minY, width: strip.width, height: max(1, strip.height * m))).fill()
        }
    }

    /// Letters stacked top to bottom, centred in the column, like TMOG's "CPU".
    private func drawVerticalLabel(_ text: String, in r: NSRect, color: NSColor) {
        let font = Self.labelFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(0.92)]
        let letters = text.map(String.init)
        let step: CGFloat = min(7, (r.height - 1) / CGFloat(max(letters.count, 1)))
        let cap = font.capHeight
        let top = r.midY + step * CGFloat(letters.count - 1) / 2
        for (i, ch) in letters.enumerated() {
            let s = NSAttributedString(string: ch, attributes: attrs)
            let w = s.size().width
            let baseline = top - CGFloat(i) * step - cap / 2
            s.draw(at: NSPoint(x: r.midX - w / 2, y: baseline + font.descender))
        }
    }

    /// White traces would vanish on a light menu bar: there they're drawn in the bar's own text colour instead.
    private func traceColor(_ c: NSColor, onLight: Bool, ink: NSColor) -> NSColor {
        guard onLight, let s = c.usingColorSpace(.sRGB), s.redComponent > 0.9, s.greenComponent > 0.9, s.blueComponent > 0.9 else { return c }
        return ink
    }

    private func drawNetwork(in r: NSRect, up: [Double], down: [Double], upText: String, downText: String,
                             label: NSColor, font: NSFont) {
        // the numbers sit on the bar itself; the graph sits on its plate, the same one the CPU and GPU charts use
        let upColor = traceColor(self.upColor, onLight: barIsLight, ink: .labelColor)
        let downColor = traceColor(self.downColor, onLight: barIsLight, ink: .labelColor)
        let g = NSRect(x: r.minX, y: 3, width: Self.graphWidth, height: r.height - 6)
        let mid = g.midY
        if netShowsGraph {
            let plateInk = ink(netPlate)
            let upColor = traceColor(self.upColor, onLight: onLight(netPlate), ink: plateInk)
            let downColor = traceColor(self.downColor, onLight: onLight(netPlate), ink: plateInk)
            fillPlate(netPlate, around: g)
            plateInk.withAlphaComponent(0.14).setFill()
            NSBezierPath(rect: g).fill()
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
            plateInk.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: g.minX, y: mid - 0.5, width: g.width, height: 1)).fill()
        }
        guard netShowsText else { return }

        let tx = netShowsGraph ? g.maxX + 4 : r.minX
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
            color = b.externalConnected ? .labelColor : .secondaryLabelColor   // plugged in: full-strength text
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        NSAttributedString(string: top, attributes: [.font: font, .foregroundColor: label, .paragraphStyle: para])
            .draw(in: NSRect(x: r.minX, y: mid - 0.5, width: r.width, height: 11))
        NSAttributedString(string: bottom, attributes: [.font: NSFont.systemFont(ofSize: b.externalConnected && b.direction == .idle ? 8.5 : 8, weight: .heavy),
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
