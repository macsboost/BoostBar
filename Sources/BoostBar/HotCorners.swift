import AppKit

/// Screen corners that trigger an action when the pointer rests in them for a moment.
/// Uses NSEvent.mouseLocation polling — no permission needed.
enum Corner: Int, CaseIterable {
    case none, topLeft, topRight, bottomLeft, bottomRight
    var title: String {
        switch self {
        case .none: return "Off"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

final class HotCorners {
    var onCorner: ((Corner, NSScreen) -> Void)?
    var watched: Set<Corner> = [] { didSet { update() } }
    var dwell: TimeInterval = 0.35

    private var timer: Timer?
    private var current: Corner = .none
    private var enteredAt: TimeInterval = 0
    private var fired = false

    private func update() {
        let on = !watched.subtracting([.none]).isEmpty
        if on, timer == nil {
            let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else {
            current = .none
            return
        }
        let f = screen.frame, m: CGFloat = 2
        let left = p.x <= f.minX + m, right = p.x >= f.maxX - m - 1
        let bottom = p.y <= f.minY + m, top = p.y >= f.maxY - m - 1
        let c: Corner = top && left ? .topLeft : top && right ? .topRight
            : bottom && left ? .bottomLeft : bottom && right ? .bottomRight : .none
        if c != current {
            current = c
            enteredAt = now
            fired = false
            return
        }
        if c != .none, !fired, watched.contains(c), now - enteredAt >= dwell {
            fired = true
            onCorner?(c, screen)
        }
    }
}

/// A small HUD message that fades out near a screen corner.
final class Toast {
    static let shared = Toast()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String, near corner: Corner, on screen: NSScreen) {
        let p = panel ?? makePanel()
        panel = p
        let label = p.contentView?.viewWithTag(1) as? NSTextField
        let icon = p.contentView?.viewWithTag(2) as? NSImageView
        label?.stringValue = text
        icon?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
        let size = NSSize(width: 260, height: 56)
        let v = screen.visibleFrame, inset: CGFloat = 18
        let x = (corner == .topLeft || corner == .bottomLeft) ? v.minX + inset : v.maxX - size.width - inset
        let y = (corner == .topLeft || corner == .topRight) ? v.maxY - size.height - inset : v.minY + inset
        p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p?.animator().alphaValue = 0 }) { p?.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 56), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.appearance = NSAppearance(named: .darkAqua)
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        let icon = NSImageView(frame: NSRect(x: 14, y: 12, width: 32, height: 32))
        icon.tag = 2
        icon.contentTintColor = NSColor(hex: "#74FB4C")
        fx.addSubview(icon)
        let label = NSTextField(labelWithString: "")
        label.tag = 1
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: 54, y: 17, width: 196, height: 22)
        fx.addSubview(label)
        p.contentView = fx
        return p
    }
}
