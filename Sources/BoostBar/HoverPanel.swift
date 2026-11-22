import AppKit

/// What the big hover tooltip shows: a title, a few text lines, and a mirrored chart
/// (one series grows up from the center line, the other grows down).
struct HoverContent {
    struct Series {
        var label: String
        var values: [Double]
        var color: NSColor
        var format: (Double) -> String
    }
    var title: String
    var lines: [String]
    var top: Series
    var bottom: Series
    var timespan: String   // e.g. "last 5 min"
}

/// Floating, non-activating HUD panel anchored under a status-bar segment.
final class HoverPanel {
    static let shared = HoverPanel()

    private let panel: NSPanel
    private let chart = HoverChartView(frame: .zero)
    private(set) var isVisible = false

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        chart.autoresizingMask = [.width, .height]
        fx.addSubview(chart)
        panel.contentView = fx
    }

    /// `anchor` is the segment's rect in screen coordinates.
    func show(_ content: HoverContent, below anchor: NSRect) {
        chart.content = content
        let size = HoverChartView.preferredSize(for: content)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = anchor.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        chart.frame = NSRect(origin: .zero, size: size)
        chart.needsDisplay = true
        panel.orderFrontRegardless()
        isVisible = true
    }

    func update(_ content: HoverContent) {
        guard isVisible else { return }
        chart.content = content
        chart.needsDisplay = true
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
    }
}

final class HoverChartView: NSView {
    var content: HoverContent?

    private static let width: CGFloat = 400
    private static let chartHeight: CGFloat = 120
    private static let lineHeight: CGFloat = 16

    static func preferredSize(for c: HoverContent) -> NSSize {
        NSSize(width: width, height: 14 + 20 + CGFloat(c.lines.count) * lineHeight + 10 + chartHeight + 34 + 12)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = content else { return }
        let w = bounds.width
        let white = NSColor.white
        let dim = NSColor.white.withAlphaComponent(0.6)

        var y: CGFloat = 14
        NSAttributedString(string: c.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: white,
        ]).draw(at: NSPoint(x: 16, y: y))
        y += 20
        for line in c.lines {
            NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: dim,
            ]).draw(at: NSPoint(x: 16, y: y))
            y += Self.lineHeight
        }
        y += 10

        // Chart
        let r = NSRect(x: 16, y: y, width: w - 32, height: Self.chartHeight)
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        let mid = r.midY
        let half = r.height / 2 - 6

        // grid
        NSColor.white.withAlphaComponent(0.08).setFill()
        for f in [0.5, 1.0] as [CGFloat] {
            NSBezierPath(rect: NSRect(x: r.minX + 6, y: mid - half * f, width: r.width - 12, height: 0.5)).fill()
            NSBezierPath(rect: NSRect(x: r.minX + 6, y: mid + half * f, width: r.width - 12, height: 0.5)).fill()
        }

        drawSeries(c.top, in: r, mid: mid, half: half, up: true)
        drawSeries(c.bottom, in: r, mid: mid, half: half, up: false)

        NSColor.white.withAlphaComponent(0.4).setFill()
        NSBezierPath(rect: NSRect(x: r.minX, y: mid - 0.5, width: r.width, height: 1)).fill()

        // Peak labels inside the chart corners
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium), .foregroundColor: dim]
        let topPeak = c.top.values.max() ?? 0
        let botPeak = c.bottom.values.max() ?? 0
        ("peak " + c.top.format(topPeak) as NSString).draw(at: NSPoint(x: r.maxX - 90, y: r.minY + 4), withAttributes: small)
        ("peak " + c.bottom.format(botPeak) as NSString).draw(at: NSPoint(x: r.maxX - 90, y: r.maxY - 15), withAttributes: small)
        (c.timespan as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 15), withAttributes: small)
        ("now" as NSString).draw(at: NSPoint(x: r.maxX - 24, y: mid + 3), withAttributes: small)

        // Legend
        y = r.maxY + 10
        var x: CGFloat = 16
        for (s, arrow) in [(c.top, "▲"), (c.bottom, "▼")] {
            let a = NSMutableAttributedString(string: arrow + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: s.color,
            ])
            a.append(NSAttributedString(string: "\(s.label)  \(s.format(s.values.last ?? 0))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: white,
            ]))
            a.draw(at: NSPoint(x: x, y: y))
            x += max(a.size().width + 24, 170)
        }
    }

    private func drawSeries(_ s: HoverContent.Series, in r: NSRect, mid: CGFloat, half: CGFloat, up: Bool) {
        let vals = s.values
        guard vals.count > 1 else { return }
        let peak = max(vals.max() ?? 0, 1e-9)
        let step = (r.width - 12) / CGFloat(vals.count - 1)
        let x0 = r.minX + 6

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0, y: mid))
        for (i, v) in vals.enumerated() {
            let h = CGFloat(max(v, 0) / peak) * half
            path.line(to: NSPoint(x: x0 + CGFloat(i) * step, y: up ? mid - h : mid + h))
        }
        path.line(to: NSPoint(x: x0 + CGFloat(vals.count - 1) * step, y: mid))
        path.close()
        s.color.withAlphaComponent(0.28).setFill()
        path.fill()

        let line = NSBezierPath()
        for (i, v) in vals.enumerated() {
            let h = CGFloat(max(v, 0) / peak) * half
            let p = NSPoint(x: x0 + CGFloat(i) * step, y: up ? mid - h : mid + h)
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        s.color.setStroke()
        line.stroke()
    }
}
