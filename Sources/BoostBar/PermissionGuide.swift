import AppKit

/// A small window that shows *where* to flip the switch for BoostBar in
/// System Settings ▸ Privacy & Security ▸ Accessibility, with a button that opens that pane.
/// Closes itself as soon as macOS reports the permission is granted.
final class PermissionGuide: NSObject, NSWindowDelegate {
    static let shared = PermissionGuide()

    private var window: NSWindow?
    private var pollTimer: Timer?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let w = window, w.isVisible { return }   // already on screen: don't steal focus again
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if ScrollReverser.hasPermission { self?.close() }
        }
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func openSettings() {
        // Registers BoostBar in the Accessibility list (so its switch exists), then opens the pane.
        ScrollReverser.promptForPermission()
        ScrollReverser.openAccessibilitySettings()
    }

    @objc private func later() { close() }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: 540, height: 470)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Turn on BoostBar in Accessibility"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: size))

        let title = NSTextField(labelWithString: "Reverse Mouse Scrolling needs permission")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: size.height - 44, width: size.width - 48, height: 22)
        content.addSubview(title)

        let illustration = AccessibilitySettingsIllustration(frame: NSRect(x: 24, y: 168, width: size.width - 48, height: 250))
        content.addSubview(illustration)

        let steps = NSTextField(wrappingLabelWithString: """
        1.  Click “Open Settings” below.
        2.  In Privacy & Security ▸ Accessibility, turn on the switch next to BoostBar.
             Not in the list? Click + at the bottom and choose BoostBar from Applications.
        3.  This window closes by itself once it’s on.
        """)
        steps.font = .systemFont(ofSize: 12)
        steps.frame = NSRect(x: 24, y: 62, width: size.width - 48, height: 96)
        content.addSubview(steps)

        let open = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.frame = NSRect(x: size.width - 24 - 140, y: 18, width: 140, height: 32)
        content.addSubview(open)

        let later = NSButton(title: "Later", target: self, action: #selector(later))
        later.bezelStyle = .rounded
        later.keyEquivalent = "\u{1b}"
        later.frame = NSRect(x: size.width - 24 - 140 - 8 - 90, y: 18, width: 90, height: 32)
        content.addSubview(later)

        w.contentView = content
        return w
    }
}

/// A simplified drawing of the Accessibility settings pane with BoostBar's switch highlighted.
/// The switch animates off → on so it's obvious what to click.
final class AccessibilitySettingsIllustration: NSView {
    private var progress: CGFloat = 0     // 0 = off, 1 = on
    private var timer: Timer?
    private var phase: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private func tick() {
        // 2.4 s loop: hold off, slide on, hold on, snap back.
        phase = (phase + 1.0 / 30).truncatingRemainder(dividingBy: 2.4)
        let p: Double
        switch phase {
        case ..<0.6: p = 0
        case ..<0.9: p = (phase - 0.6) / 0.3
        default: p = 1
        }
        progress = CGFloat(p * p * (3 - 2 * p))  // smoothstep
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let label = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        let accent = NSColor.controlAccentColor

        // Window frame
        let frame = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill(); frame.fill()
        NSColor.separatorColor.setStroke(); frame.lineWidth = 1; frame.stroke()

        // Sidebar
        let sidebarW: CGFloat = 150
        let sidebar = NSRect(x: 0, y: 0, width: sidebarW, height: b.height)
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        NSColor.underPageBackgroundColor.setFill()
        NSBezierPath(rect: sidebar).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Traffic lights
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(i) * 16, y: 12, width: 10, height: 10)).fill()
        }

        let small = NSFont.systemFont(ofSize: 11)
        let items = ["Wi-Fi", "Bluetooth", "Network", "Notifications", "Sound", "Focus", "Privacy & Security", "Desktop & Dock"]
        var y: CGFloat = 40
        for item in items {
            let selected = item == "Privacy & Security"
            if selected {
                accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: y - 3, width: sidebarW - 16, height: 20), xRadius: 5, yRadius: 5).fill()
            }
            // little icon square
            (selected ? NSColor.white : NSColor.systemGray).withAlphaComponent(selected ? 0.9 : 0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: y + 1, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
            NSAttributedString(string: item, attributes: [
                .font: selected ? NSFont.systemFont(ofSize: 11, weight: .semibold) : small,
                .foregroundColor: selected ? NSColor.white : label,
            ]).draw(at: NSPoint(x: 34, y: y))
            y += 24
        }

        // Right pane
        let px = sidebarW + 18
        let pw = b.width - px - 16
        NSAttributedString(string: "‹  Accessibility", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: label,
        ]).draw(at: NSPoint(x: px, y: 14))
        NSAttributedString(string: "Allow the applications below to control your computer.", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: secondary,
        ]).draw(at: NSPoint(x: px, y: 44))

        // List box
        let list = NSRect(x: px, y: 66, width: pw, height: 132)
        NSColor.controlBackgroundColor.setFill()
        let listPath = NSBezierPath(roundedRect: list, xRadius: 8, yRadius: 8)
        listPath.fill()
        NSColor.separatorColor.setStroke(); listPath.stroke()

        let rowH: CGFloat = 40
        let rows: [(String, Bool)] = [("Some Other App", false), ("BoostBar", true), ("Another App", false)]
        for (i, row) in rows.enumerated() {
            let ry = list.minY + CGFloat(i) * rowH + 3
            let isBoost = row.1
            if i > 0 {
                NSColor.separatorColor.setFill()
                NSBezierPath(rect: NSRect(x: list.minX + 12, y: ry - 2, width: list.width - 24, height: 1)).fill()
            }
            // App icon
            let iconRect = NSRect(x: list.minX + 12, y: ry + 6, width: 24, height: 24)
            if isBoost, let icon = NSApp.applicationIconImage {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor.systemGray.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: iconRect, xRadius: 6, yRadius: 6).fill()
            }
            NSAttributedString(string: row.0, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isBoost ? .semibold : .regular),
                .foregroundColor: isBoost ? label : secondary,
            ]).draw(at: NSPoint(x: iconRect.maxX + 10, y: ry + 11))

            // Switch
            let sw = NSRect(x: list.maxX - 12 - 34, y: ry + 9, width: 34, height: 20)
            let on: CGFloat = isBoost ? progress : 0
            let track = NSBezierPath(roundedRect: sw, xRadius: 10, yRadius: 10)
            NSColor.systemGray.withAlphaComponent(0.35).blended(withFraction: on, of: accent)?.setFill()
            track.fill()
            let knobX = sw.minX + 2 + (sw.width - 20) * on
            NSColor.white.setFill()
            let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: sw.minY + 2, width: 16, height: 16))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
            knob.fill()
            NSGraphicsContext.restoreGraphicsState()

            if isBoost {
                // Highlight ring around the BoostBar row + callout
                let ring = NSBezierPath(roundedRect: NSRect(x: list.minX + 4, y: ry, width: list.width - 8, height: rowH - 4), xRadius: 6, yRadius: 6)
                ring.lineWidth = 2.5
                NSColor.systemOrange.setStroke(); ring.stroke()

                let callout = "Turn this on"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
                let tsize = (callout as NSString).size(withAttributes: attrs)
                // Bubble sits just left of the switch, in the same row, with an arrow pointing at it.
                let bubble = NSRect(x: sw.minX - 12 - (tsize.width + 16), y: sw.midY - (tsize.height + 6) / 2,
                                    width: tsize.width + 16, height: tsize.height + 6)
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: bubble, xRadius: 6, yRadius: 6).fill()
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: bubble.maxX, y: sw.midY - 5))
                arrow.line(to: NSPoint(x: bubble.maxX + 8, y: sw.midY))
                arrow.line(to: NSPoint(x: bubble.maxX, y: sw.midY + 5))
                arrow.close(); arrow.fill()
                (callout as NSString).draw(at: NSPoint(x: bubble.minX + 8, y: bubble.minY + 3), withAttributes: attrs)
            }
        }

        NSAttributedString(string: "System Settings ▸ Privacy & Security ▸ Accessibility", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: secondary,
        ]).draw(at: NSPoint(x: px, y: list.maxY + 16))
    }
}
