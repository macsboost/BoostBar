import AppKit

/// Drawn inside the NSStatusItem button. Each segment can be turned on/off:
///  [●] [ upload bars ↑ | download bars ↓ ] ▲ 12 KB/s   8.4W
///                                        ▼ 340 KB/s   OUT
final class StatusGraphView: NSView {
    enum AwakeState { case normal, keepAwake, lidAwake }

    // Content
    var up: [Double] = []
    var down: [Double] = []
    var upText = "0.0 KB/s"
    var downText = "0.0 KB/s"
    var awake: AwakeState = .normal
    var battery: BatteryReading?

    // Which segments to show
    var showNetwork = true
    var showBattery = false

    static let upColor = NSColor.systemRed
    static let downColor = NSColor.systemBlue
    static let chargeColor = NSColor.systemGreen
    static let dischargeColor = NSColor.systemOrange

    private static let pad: CGFloat = 3
    private static let dotWidth: CGFloat = 6
    private static let graphWidth: CGFloat = 30
    private static let netTextWidth: CGFloat = 58
    private static let batteryWidth: CGFloat = 30
    private static let iconWidth: CGFloat = 20

    private var showsBattery: Bool { showBattery && battery != nil }

    /// Segment rects in this view's coordinates (used for hover tooltips).
    private(set) var networkRect = NSRect.zero
    private(set) var batteryRect = NSRect.zero

    /// Lays out the segments and returns the total width the status item needs.
    @discardableResult
    func layoutSegments(height h: CGFloat) -> CGFloat {
        var x = Self.pad
        if awake != .normal || (!showNetwork && !showsBattery) { x += Self.dotWidth }
        if !showNetwork && !showsBattery {
            networkRect = .zero; batteryRect = .zero
            return x + Self.iconWidth + Self.pad
        }
        if showNetwork {
            networkRect = NSRect(x: x, y: 0, width: Self.graphWidth + 4 + Self.netTextWidth, height: h)
            x = networkRect.maxX
        } else {
            networkRect = .zero
        }
        if showsBattery {
            if showNetwork { x += 2 }
            batteryRect = NSRect(x: x, y: 0, width: Self.batteryWidth, height: h)
            x = batteryRect.maxX
        } else {
            batteryRect = .zero
        }
        return x + Self.pad
    }

    // Let clicks fall through to the status button so the menu opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        layoutSegments(height: h)
        let label = NSColor.labelColor
        let mid = h / 2

        // Keep-awake indicator dot
        if awake != .normal {
            let color: NSColor = (awake == .lidAwake) ? .systemOrange : .systemYellow
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: Self.pad, y: mid - 2, width: 4, height: 4)).fill()
        }

        if !showNetwork && !showsBattery {
            let x = Self.pad + Self.dotWidth
            if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "BoostBar") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                let sized = img.withSymbolConfiguration(cfg) ?? img
                let s = sized.size
                let tinted = NSImage(size: s, flipped: false) { r in
                    sized.draw(in: r)
                    label.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: x + (Self.iconWidth - s.width) / 2, y: (h - s.height) / 2, width: s.width, height: s.height))
            }
            return
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

        if showNetwork { drawNetwork(in: networkRect, label: label, font: font) }
        if showsBattery, let b = battery { drawBattery(b, in: batteryRect, label: label, font: font) }
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

        Self.upColor.setFill()
        for (i, v) in up.enumerated() where v > 0 {
            let bh = max(CGFloat(v / maxUp) * half, 0.5)
            NSBezierPath(rect: NSRect(x: g.minX + CGFloat(i) * barW, y: mid + 0.5, width: barW, height: bh)).fill()
        }
        Self.downColor.setFill()
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
        line("▲", Self.upColor, upText).draw(at: NSPoint(x: tx, y: mid - 0.5))
        line("▼", Self.downColor, downText).draw(at: NSPoint(x: tx, y: mid - 11))
    }

    private func drawBattery(_ b: BatteryReading, in r: NSRect, label: NSColor, font: NSFont) {
        let mid = r.height / 2
        let top: String
        let bottom: String
        let color: NSColor
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
        let topStr = NSAttributedString(string: top, attributes: [.font: font, .foregroundColor: label, .paragraphStyle: para])
        let botFont = NSFont.systemFont(ofSize: 8, weight: .bold)
        let botStr = NSAttributedString(string: bottom, attributes: [.font: botFont, .foregroundColor: color, .paragraphStyle: para])
        topStr.draw(in: NSRect(x: r.minX, y: mid - 0.5, width: r.width, height: 11))
        botStr.draw(in: NSRect(x: r.minX, y: mid - 11, width: r.width, height: 11))
    }
}
