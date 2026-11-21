import AppKit

/// Drawn inside the NSStatusItem button:
///  [●] [ upload bars grow up  ] ▲ 12 KB/s
///      [ download bars grow dn] ▼ 340 KB/s
final class StatusGraphView: NSView {
    enum AwakeState { case normal, keepAwake, lidAwake }

    var up: [Double] = []
    var down: [Double] = []
    var upText = "0.0 KB/s"
    var downText = "0.0 KB/s"
    var awake: AwakeState = .normal

    static let dotWidth: CGFloat = 6
    static let graphWidth: CGFloat = 30
    static let textWidth: CGFloat = 58
    static let totalWidth: CGFloat = 3 + dotWidth + graphWidth + 4 + textWidth + 2

    static let upColor = NSColor.systemRed
    static let downColor = NSColor.systemBlue

    // Let clicks fall through to the status button so the menu opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let label = NSColor.labelColor

        // Keep-awake indicator dot
        var x: CGFloat = 3
        if awake != .normal {
            let color: NSColor = (awake == .lidAwake) ? .systemOrange : .systemYellow
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: h / 2 - 2, width: 4, height: 4)).fill()
        }
        x += Self.dotWidth

        // Graph box
        let g = NSRect(x: x, y: 3, width: Self.graphWidth, height: h - 6)
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

        // Text
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let tx = g.maxX + 4
        func line(_ arrow: String, _ color: NSColor, _ text: String) -> NSAttributedString {
            let s = NSMutableAttributedString(string: arrow, attributes: [.font: font, .foregroundColor: color])
            s.append(NSAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: label]))
            return s
        }
        line("▲", Self.upColor, upText).draw(at: NSPoint(x: tx, y: mid - 0.5))
        line("▼", Self.downColor, downText).draw(at: NSPoint(x: tx, y: mid - 11))
    }
}
