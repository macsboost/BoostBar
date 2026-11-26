import AppKit

/// A checkbox that reports the pointer entering and leaving it (Settings ▸ Eyes previews an emotion on hover).
final class HoverCheckbox: NSButton {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
    override func viewWillMove(toWindow w: NSWindow?) {
        if w == nil { onHover?(false) }
        super.viewWillMove(toWindow: w)
    }
}

/// Holds closures for AppKit target/action.
private final class ActionBox: NSObject {
    let fire: (Any?) -> Void
    init(_ fire: @escaping (Any?) -> Void) { self.fire = fire }
    @objc func run(_ sender: Any?) { fire(sender) }
}

/// The rounded, lightly tinted box a group of settings sits in (like System Settings).
private final class CardView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
/// A row indented under the control above it.
private final class IndentRow: NSStackView {}

/// One settings tab: titled cards of controls, each control with a refresher that re-reads its state.
private final class Pane: NSViewController {
    static let width: CGFloat = 700
    private static let margin: CGFloat = 24
    private static let cardPad: CGFloat = 14
    private static let labelWidth: CGFloat = 124
    /// Width available to a control inside a card.
    static let innerWidth: CGFloat = width - 2 * margin - 2 * cardPad

    private let stack = NSStackView()
    private var card: NSStackView?
    /// When the section being built only shows some of the time (see `header`).
    private var sectionVisible: (() -> Bool)?
    private var refreshers: [() -> Void] = []
    private var boxes: [ActionBox] = []
    private let build: (Pane) -> Void
    /// Called after a refresh, when rows may have appeared or gone (the window refits itself).
    var onLayout: (() -> Void)?

    init(title: String, symbol: String, build: @escaping (Pane) -> Void) {
        self.build = build
        super.init(nibName: nil, bundle: nil)
        self.title = title
        _ = symbol
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: Self.margin, bottom: 22, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 480))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        view = scroll
        build(self)
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        refreshers.forEach { $0() }
        onLayout?()
    }

    /// The height this tab needs to show everything.
    var fittingHeight: CGFloat {
        _ = view
        stack.layoutSubtreeIfNeeded()
        return ceil(stack.fittingSize.height)
    }

    /// A retained action target for controls built by hand inside a pane.
    func actionBox(_ f: @escaping (Any?) -> Void) -> ActionBox { box(f) }

    private func box(_ f: @escaping (Any?) -> Void) -> ActionBox {
        let b = ActionBox(f); boxes.append(b); return b
    }

    // MARK: Structure

    /// Starts a new card, under a title. With `visible`, the title and its card only show while that holds.
    func header(_ text: String, visible: (() -> Bool)? = nil) {
        card = nil
        sectionVisible = visible
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
        let r = NSStackView(views: [t])
        r.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        stack.addArrangedSubview(r)
        stack.setCustomSpacing(6, after: r)
        if let visible { refreshers.append { [weak r] in r?.isHidden = !visible() } }
    }

    /// Small print under the cards.
    func footnote(_ text: String) {
        card = nil
        sectionVisible = nil
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .tertiaryLabelColor
        t.preferredMaxLayoutWidth = Self.width - 2 * Self.margin - 8
        let r = NSStackView(views: [t])
        r.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(10, after: last) }
        stack.addArrangedSubview(r)
    }

    /// The card being filled (a new one if the last was closed).
    private var content: NSStackView {
        if let card { return card }
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        let box = CardView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        let p = Self.cardPad
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: p),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -p),
            box.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.margin),
        ])
        stack.addArrangedSubview(box)
        if let visible = sectionVisible { refreshers.append { [weak box] in box?.isHidden = !visible() } }
        card = inner
        return inner
    }

    /// A thin line between groups inside one card.
    func divider() {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let c = content
        if let last = c.arrangedSubviews.last { c.setCustomSpacing(10, after: last) }
        c.addArrangedSubview(line)
        line.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        c.setCustomSpacing(10, after: line)
    }

    // MARK: Builders

    private func fieldLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        return l
    }

    func note(_ text: String, indent: Bool = false) {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = Self.innerWidth - (indent ? 20 : 0)
        add(t, indent: indent)
    }

    @discardableResult
    func check(_ title: String, indent: Bool = false,
               get: @escaping () -> Bool, set: @escaping (Bool) -> Void,
               enabled: (() -> Bool)? = nil, visible: (() -> Bool)? = nil) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        let bx = box { [weak b] _ in if let b { set(b.state == .on) } }
        b.target = bx; b.action = #selector(ActionBox.run(_:))
        refreshers.append { [weak self, weak b] in
            guard let b else { return }
            b.state = get() ? .on : .off
            if let enabled { b.isEnabled = enabled() }
            if let visible { self?.setHidden(b, !visible()) }
        }
        add(b, indent: indent)
        return b
    }

    func popup(_ label: String, items: [String], indent: Bool = false,
               get: @escaping () -> Int, set: @escaping (Int) -> Void,
               trailing: NSView? = nil, enabled: (() -> Bool)? = nil) {
        let l = fieldLabel(label)
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        let bx = box { [weak p] _ in if let p { set(p.indexOfSelectedItem) } }
        p.target = bx; p.action = #selector(ActionBox.run(_:))
        refreshers.append { [weak p] in
            p?.selectItem(at: get())
            if let enabled { p?.isEnabled = enabled() }
        }
        var views: [NSView] = [l, p]
        if let trailing { views.append(trailing) }
        add(row(views), indent: indent)
    }

    /// A labelled slider with a live read-out of its value, an optional caption and trailing control.
    func slider(_ label: String, min: Double, max: Double, get: @escaping () -> Double, set: @escaping (Double) -> Void,
                value: ((Double) -> String)? = nil, caption: String? = nil, trailing: NSView? = nil,
                enabled: (() -> Bool)? = nil, visible: (() -> Bool)? = nil) {
        let l = fieldLabel(label)
        let s = NSSlider(value: get(), minValue: min, maxValue: max, target: nil, action: nil)
        s.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let readout = NSTextField(labelWithString: "")
        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let bx = box { [weak s, weak readout] _ in
            guard let s else { return }
            set(s.doubleValue)
            if let value { readout?.stringValue = value(get()) }
        }
        s.target = bx; s.action = #selector(ActionBox.run(_:))
        var views: [NSView] = [l, s]
        if value != nil { views.append(readout) }
        if let caption {
            let c = NSTextField(labelWithString: caption)
            c.font = .systemFont(ofSize: 11); c.textColor = .secondaryLabelColor
            views.append(c)
        }
        if let trailing { views.append(trailing) }
        let r = row(views)
        refreshers.append { [weak self, weak s, weak readout, weak r] in
            s?.doubleValue = get()
            if let value { readout?.stringValue = value(get()) }
            if let enabled { s?.isEnabled = enabled() }
            if let visible, let r { self?.setHidden(r, !visible()) }
        }
        add(r, indent: false)
    }

    func color(_ label: String, get: @escaping () -> NSColor, set: @escaping (NSColor) -> Void) {
        let l = fieldLabel(label)
        let w = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        w.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let bx = box { [weak w] _ in if let w { set(w.color) } }
        w.target = bx; w.action = #selector(ActionBox.run(_:))
        refreshers.append { [weak w] in w?.color = get() }
        add(row([l, w]), indent: false)
    }

    @discardableResult
    func button(_ title: String, indent: Bool = false, action: @escaping () -> Void) -> NSButton {
        let b = makeButton(title, action: action)
        add(b, indent: indent)
        return b
    }

    /// A row of buttons (or other small views), optionally after a field label.
    func buttons(_ views: [NSView], label: String? = nil) {
        add(row((label.map { [fieldLabel($0)] } ?? []) + views), indent: false)
    }

    func makeButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let bx = box { _ in action() }
        let b = NSButton(title: title, target: bx, action: #selector(ActionBox.run(_:)))
        b.bezelStyle = .rounded
        return b
    }

    /// Status text that follows the app's state; the row disappears while it's empty.
    func label(indent: Bool = false, get: @escaping () -> String) {
        let t = NSTextField(wrappingLabelWithString: "")
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = Self.innerWidth - (indent ? 20 : 0)
        refreshers.append { [weak self, weak t] in
            guard let t else { return }
            let s = get()
            t.stringValue = s
            self?.setHidden(t, s.isEmpty)
        }
        add(t, indent: indent)
    }

    /// A full-width view of fixed height (a table, an editor).
    func custom(_ v: NSView, height: CGFloat, onRefresh: (() -> Void)? = nil) {
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(v)
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        v.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        if let onRefresh { refreshers.append(onRefresh) }
    }

    /// Any hand-built row, with its own refresher.
    func addRow(_ v: NSView, onRefresh: (() -> Void)? = nil) {
        add(v, indent: false)
        if let onRefresh { refreshers.append(onRefresh) }
    }

    func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    /// Hides a control (and the indent wrapper it may sit in) so its row closes up.
    func setHidden(_ v: NSView, _ hidden: Bool) {
        if let w = v.superview as? IndentRow { w.isHidden = hidden }
        v.isHidden = hidden
    }

    private func add(_ v: NSView, indent: Bool) {
        if indent {
            let r = IndentRow(views: [v])
            r.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            content.addArrangedSubview(r)
        } else {
            content.addArrangedSubview(v)
        }
    }
}

/// Tabs that tell the window when the selection changes, so it can fit itself to the tab.
private final class Tabs: NSTabViewController {
    var onSelect: (() -> Void)?
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}

/// BoostBar ▸ Settings… — every option, grouped in tabs.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private unowned let app: AppDelegate
    private var window: NSWindow?
    private var tabs: Tabs?
    /// Which saver the Screen Saver tab opens on (the settings snapshots set it).
    static var initialSaver = 0
    private var panes: [Pane] = []
    private var drivesTable: DiskDrivesTable?
    private var observer: NSObjectProtocol?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        observer = NotificationCenter.default.addObserver(forName: .boostBarStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func show(tab: String? = nil) {
        let w = window ?? makeWindow()
        window = w
        if let tab, let tabs, let i = panes.firstIndex(where: { $0.title == tab }) { tabs.selectedTabViewItemIndex = i }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if !w.isVisible { fit(animated: false); w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard window?.isVisible == true else { return }
        drivesTable?.reload()
        panes.forEach { if $0.isViewLoaded { $0.refresh() } }
    }

    /// Sizes the window to the selected tab (up to the screen's height; a taller tab scrolls), keeping its top edge put.
    private var fitting = false
    private func fit(animated: Bool) {
        guard !fitting, let w = window, let tabs, panes.indices.contains(tabs.selectedTabViewItemIndex) else { return }
        fitting = true; defer { fitting = false }
        let pane = panes[tabs.selectedTabViewItemIndex]
        let room = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let chrome = w.frame.height - w.contentLayoutRect.height
        let h = min(pane.fittingHeight, max(320, room - chrome - 24))
        var f = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Pane.width, height: h))
        f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
        if f.size != w.frame.size { w.setFrame(f, display: true, animate: animated && w.isVisible) }
    }

    /// Renders every tab to PNGs in `dir` (run with --snapshot-settings; used to check the layout in CI).
    func snapshot(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shoot(_ name: String) {
            guard let w = window, let v = w.contentView else { return }
            fit(animated: false)
            v.layoutSubtreeIfNeeded(); w.displayIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.lockFocus()
            NSColor.windowBackgroundColor.setFill(); v.bounds.fill()
            rep.draw(in: v.bounds)
            img.unlockFocus()
            if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
                print("settings snapshot", name, Int(v.bounds.width), "x", Int(v.bounds.height))
            }
        }
        // the menu bar pieces too, on a light and a dark bar, at 4x so the tiny gauge can be judged
        for (name, dark) in [("menubar_light", false), ("menubar_dark", true)] {
            for (k, load) in [0.08, 0.45, 0.93].enumerated() {
                for style in 0...1 {
                    let v = StatusGraphView(frame: .zero)
                    v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    v.showNetwork = true; v.showBattery = true; v.showDisks = true; v.showEyes = true; v.eyeSize = 2
                    v.battery = BatteryReading(watts: [-8.4, 42, -23.5][k], percent: 70, externalConnected: k == 1, isCharging: k == 1, fullyCharged: false); v.leds = [.init(key: "a", color: .systemGreen)]; v.ledSize = 1
                    v.showCPU = true; v.cpuStyle = style; v.cpu = load; v.cpuBackdrop = [-0.7, 0, 0.7][k]
                    v.cpuCores = (0..<10).map { min(1, max(0.02, load + 0.35 * sin(Double($0) * 1.7 + Double(k)))) }
                    if style == 1 {
                        v.cpuPeaks = v.cpuCores.enumerated().map { i, c -> Double in
                            let extra: Double = 0.12 + 0.1 * Double(i % 3)
                            return min(1.0, c + extra)
                        }
                    }
                    v.verticalLabels = k == 1
                    v.up = (0..<30).map { 2000 + 9000 * abs(sin(Double($0) * 0.4)) }; v.down = (0..<30).map { 40000 * abs(cos(Double($0) * 0.3)) }
                    v.upText = "12 KB/s"; v.downText = "340 KB/s"
                    let w = v.layoutSegments(height: 22)
                    v.frame = NSRect(x: 0, y: 0, width: w, height: 22)
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w) * 4, pixelsHigh: 88, bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                    rep.size = v.bounds.size
                    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
                        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); v.bounds.fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)_\(k)_\(style).png"))
                    }
                }
            }
        }
        // every emotion, large eyes at 6x, on a dark and a light bar
        for lash in 0...2 { for dark in [true, false] {
            let faces: [(String, EyeFace, Bool)] = [("plain", EyeFace(), false)] + Emotion.allCases.flatMap { e -> [(String, EyeFace, Bool)] in
                var f = EyeFace.pose(e, level: 0.7)
                if e == .hearts { var g = f; g.symbol = 2; return [(e.rawValue, f, false), ("dollar", g, false)] }
                if e == .startled { f.lift = 1.5 }
                return [(e.rawValue, f, false)]
            }
            let cellW = 48, scale = 6
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cellW * faces.count * scale, pixelsHigh: 22 * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: cellW * faces.count, height: 22)
            guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: cellW * faces.count, height: 22).fill()
            NSGraphicsContext.restoreGraphicsState()
            for (k, item) in faces.enumerated() {
                let v = StatusGraphView(frame: .zero)
                v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                v.showNetwork = false; v.showBattery = false; v.showDisks = false; v.showCPU = false
                v.showEyes = true; v.eyeSize = 2; v.lashes = lash
                v.eyeFace = item.1
                v.pupilOffsets = item.0 == "sad" || item.0 == "sleepy" ? [CGPoint(x: 0, y: -2.5), CGPoint(x: 0, y: -2.5)] : [CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0)]
                let w = v.layoutSegments(height: 22)
                v.frame = NSRect(x: 0, y: 0, width: w, height: 22)
                guard let one = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: one)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
                one.draw(in: NSRect(x: CGFloat(k * cellW) + (CGFloat(cellW) - w) / 2, y: 0, width: w, height: 22))
                NSGraphicsContext.restoreGraphicsState()
            }
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar_emotions\(lash == 0 ? "" : lash == 1 ? "_natural" : "_fake")_\(dark ? "dark" : "light").png"))
            }
        } }
        for saver in BundledSaver.all.indices {
            Self.initialSaver = saver
            window = nil; tabs = nil
            let w = makeWindow(); window = w
            w.makeKeyAndOrderFront(nil)
            for (i, p) in panes.enumerated() {
                let screenSaver = p.title == "Screen Saver"
                if saver > 0 && !screenSaver { continue }
                tabs?.selectedTabViewItemIndex = i
                shoot((p.title ?? "tab").replacingOccurrences(of: " ", with: "") + (screenSaver ? "_\(BundledSaver.all[saver].scene)" : ""))
            }
            w.orderOut(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let tabs = Tabs()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        self.tabs = tabs

        panes = makePanes()
        let symbols: [String: String] = [
            "General": "gearshape", "CPU": "gauge.with.needle", "Sleep": "moon.zzz", "Network": "network", "Battery": "battery.75percent",
            "Disks": "internaldrive", "Eyes": "eyes", "Screen Saver": "airplane", "Scrolling": "computermouse",
        ]
        tabs.onSelect = { [weak self] in self?.fit(animated: true) }
        for p in panes {
            p.onLayout = { [weak self, weak p] in
                guard let self, let p, let t = self.tabs, self.panes.indices.contains(t.selectedTabViewItemIndex),
                      self.panes[t.selectedTabViewItemIndex] === p else { return }
                self.fit(animated: false)
            }
            let item = NSTabViewItem(viewController: p)
            item.label = p.title ?? ""
            item.image = NSImage(systemSymbolName: symbols[p.title ?? ""] ?? "circle", accessibilityDescription: p.title)
            tabs.addTabViewItem(item)
        }

        let w = NSWindow(contentViewController: tabs)
        w.title = "BoostBar Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: Pane.width, height: 480))
        return w
    }

    // MARK: Tabs

    private func makePanes() -> [Pane] {
        var list: [Pane] = []
        let app = self.app

        // General
        list.append(Pane(title: "General", symbol: "gearshape") { p in
            p.header("Startup")
            p.check("Launch BoostBar at login", get: { LoginItem.isEnabled }, set: { _ in app.toggleLaunchAtLogin() })
            p.label(indent: true) { LoginItem.needsApproval ? "Waiting for approval in System Settings ▸ General ▸ Login Items" : "" }
            #if !APPSTORE
            p.header("Updates")
            p.check("Check for updates when BoostBar starts", get: { Prefs.checkOnLaunch }, set: { Prefs.checkOnLaunch = $0 })
            p.check("Install updates automatically", indent: true, get: { Prefs.autoUpdate }, set: { Prefs.autoUpdate = $0 })
            p.note("A newer version found at startup is downloaded, checked against Apple's notarization and the MacsBoost signature, swapped in and relaunched — no prompt.", indent: true)
            p.buttons([p.makeButton("Check Now") { app.checkForUpdates() }, p.makeButton("BoostBar on GitHub") { app.openGitHub() }])
            #endif
            p.header("Menu Bar Layout")
            p.check("Label the pieces with stacked text: NET, BAT, HDD", get: { Prefs.verticalLabels },
                    set: { Prefs.verticalLabels = $0; app.applySettings() })
            p.divider()
            p.note("Order of the pieces — the top of the list is leftmost. Drag a row, or select it and use Left / Right. You can also drag a piece along the menu bar itself.")
            let editor = OrderEditor(order: { Prefs.segmentOrder }, isShown: { app.isSegmentShown($0) },
                                     onChange: { app.setOrder($0) })
            p.custom(editor, height: 134, onRefresh: { [weak editor] in editor?.reload() })
            p.button("Reset Order") { app.resetOrder() }
            p.header("Privacy")
            p.check("Share anonymous install count", get: { InstallPing.isEnabled }, set: { _ in app.toggleInstallPing() })
            p.note("Sends biz-cord.com a random ID, the BoostBar version, macOS version and CPU type, once per version. No personal info.", indent: true)
            p.header("About")
            p.buttons([p.makeButton("About BoostBar…") { app.showAbout() },
                       p.makeButton("Buy Me an Energy Drink ⚡") { app.showAbout() }])
        })

        // Sleep
        list.append(Pane(title: "Sleep", symbol: "moon.zzz") { p in
            p.header("Keep Awake")
            p.check("Keep Mac awake", get: { app.sleep.isPreventing }, set: { on in on ? app.sleep.prevent(for: nil) : app.sleep.allow() })
            p.label(indent: true) {
                if let u = app.sleep.until { return "Until \(DateFormatter.localizedString(from: u, dateStyle: .none, timeStyle: .short))" }
                return app.sleep.isPreventing ? "Until you turn it off" : ""
            }
            var forIndex = 2
            let start = p.makeButton("Start") { app.keepAwake(minutes: AppDelegate.awakeDurations[forIndex].minutes) }
            p.popup("Keep awake for", items: AppDelegate.awakeDurations.map(\.label),
                    get: { forIndex }, set: { forIndex = $0 }, trailing: start)
            p.check("Keep the display on too", get: { app.sleep.keepDisplayAwake }, set: { app.setKeepDisplayAwake($0) })
            p.note("Keep Awake is also in the BoostBar menu for one-click access.")
            #if !APPSTORE
            p.header("Lid Closed")
            p.check("Stay awake with the lid closed", get: { app.lidSleepDisabled }, set: { _ in app.toggleLidSleep() })
            p.note("Runs “pmset -a disablesleep 1” (admin password). Stays on after quitting or restarting until you turn it off. Don’t bag a running Mac with this on.", indent: true)
            p.check("Toggle lid mode without a password", indent: true, get: { LidSleep.helperInstalled }, set: { _ in app.toggleLidHelper() })
            #endif
            p.header("Hot Corners")
            let corners = Corner.allCases.map(\.title)
            p.popup("Toggle Keep Awake", items: corners, get: { Prefs.cornerAwake.rawValue },
                    set: { Prefs.cornerAwake = Corner(rawValue: $0) ?? .none; app.applySettings() })
            #if !APPSTORE
            p.popup("Sleep now", items: corners, get: { Prefs.cornerSleep.rawValue },
                    set: { Prefs.cornerSleep = Corner(rawValue: $0) ?? .none; app.applySettings() })
            #endif
            p.note("Rest the pointer in the corner for a moment. If macOS has its own Hot Corner there (System Settings ▸ Desktop & Dock ▸ Hot Corners), both will run.")
        })

        // Network
        list.append(Pane(title: "Network", symbol: "network") { p in
            p.header("Menu Bar")
            p.check("Show network speed graph", get: { Prefs.showNetwork }, set: { Prefs.showNetwork = $0; app.applySettings() })
            p.popup("Smallest unit", items: ["KB/s (steps up to MB/s, GB/s when faster)", "MB/s (steps up to GB/s when faster)"],
                    get: { Prefs.netUnit == .mega ? 1 : 0 }, set: { Prefs.netUnit = $0 == 1 ? .mega : .auto; app.applySettings() })
            p.check("Show bits per second (Kb/s, Mb/s) instead of bytes", get: { Prefs.useBits }, set: { Prefs.useBits = $0; app.applySettings() })
            p.popup("Graphs", items: ["One combined graph (all connections)", "Separate graph per connection (LAN, Wi‑Fi, …)"],
                    get: { Prefs.netSplit ? 1 : 0 }, set: { Prefs.netSplit = $0 == 1; app.applySettings() })
            p.label { app.networkSummary() }
            p.note("Hover over the graph in the menu bar for a 5-minute chart.")
            p.header("Trace Colors")
            p.color("Upload", get: { Prefs.upColor }, set: { Prefs.upColor = $0; app.applySettings() })
            p.color("Download", get: { Prefs.downColor }, set: { Prefs.downColor = $0; app.applySettings() })
            let presets = Palette.tracePresets.map { preset in
                p.makeButton(preset.name) {
                    Prefs.setTraceColors(up: preset.up, down: preset.down)
                    app.applySettings()
                    NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
                }
            }
            p.buttons(presets, label: "Presets")
        })

        // Battery
        list.append(Pane(title: "Battery", symbol: "battery.75percent") { p in
            p.header("Menu Bar")
            p.check(BatteryMonitor.hasBattery ? "Show battery power (watts in / out)" : "Show battery power (this Mac has no battery)",
                    get: { BatteryMonitor.hasBattery && Prefs.showBattery },
                    set: { Prefs.showBattery = $0; app.applySettings() },
                    enabled: { BatteryMonitor.hasBattery })
            p.note("Green IN = charging, orange OUT = running on battery. Hover for time to full / empty and a 10-minute power chart.")
        })

        // CPU
        list.append(Pane(title: "CPU", symbol: "gauge.with.needle") { p in
            p.header("Menu Bar")
            p.check("Show CPU meter", get: { Prefs.showCPU }, set: { Prefs.showCPU = $0; app.applySettings() })
            p.popup("Style", items: ["Boost gauge (half-round, with a needle)", "Spectrum analyzer (a bar per core)"],
                    get: { Prefs.cpuStyle }, set: { Prefs.cpuStyle = $0; app.applySettings(); p.refresh() })
            // a logarithmic scale: each step along the slider multiplies the rate, so 1–5 Hz gets as much room as 10–60 Hz
            let lo = 1.0, hi = 60.0
            let fromSlider: (Double) -> Double = { s in
                let r = lo * pow(hi / lo, s)
                return r < 2 ? (r * 4).rounded() / 4 : r < 10 ? (r * 2).rounded() / 2 : r.rounded()
            }
            p.slider("Update rate", min: 0, max: 1, get: { log(Prefs.cpuRate / lo) / log(hi / lo) },
                     set: { Prefs.cpuRate = fromSlider($0); app.applySettings() },
                     value: { s in let r = fromSlider(s); return r == r.rounded() ? String(format: "%.0f Hz", r) : String(format: "%g Hz", r) },
                     caption: "1 a second … 60 a second")
            p.slider("Backdrop", min: -1, max: 1, get: { Prefs.cpuBackdrop }, set: { Prefs.cpuBackdrop = $0; app.applySettings() },
                     value: { abs($0) < 0.04 ? "Off" : String(format: "%@ %.0f%%", $0 < 0 ? "Dark" : "Light", abs($0) * 100) },
                     caption: "dark ← off → light")
            p.slider("Peak hold", min: 0, max: 10, get: { Prefs.cpuPeakHold }, set: { Prefs.cpuPeakHold = ($0 * 2).rounded() / 2; app.applySettings(); p.refresh() },
                     value: { $0 < 0.2 ? "Off" : String(format: "%g s", ($0 * 2).rounded() / 2) }, caption: "spectrum analyzer: how long each core's peak marker stays",
                     visible: { Prefs.cpuStyle == 1 })
            p.note("Damping is automatic: the needle and bars glide between readings, with a longer sweep at slow rates and a quicker one at fast rates. At 20 Hz and above the meter also redraws that often (up to 60 frames a second), which uses a little more power.")
            p.divider()
            p.note("The gauge reads all cores together: green at idle, through yellow and orange, to red at full boost. Hover it for a 5-minute chart. It sits between the battery and the disk lights; move it in General ▸ Menu Bar Layout.")
        })

        // Disks
        list.append(Pane(title: "Disks", symbol: "internaldrive") { [weak self] p in
            guard let self else { return }
            p.header("Disk Activity Lights")
            p.check("Show disk lights in the menu bar", get: { app.diskSettings.showDisks },
                    set: { app.diskSettings.showDisks = $0; app.applySettings() })
            p.popup("LED size", items: Prefs.sizeNames,
                    get: { app.diskSettings.ledSize }, set: { app.diskSettings.ledSize = $0; app.applySettings() })
            p.popup("Blink duration", items: DiskLightSettings.durations.map { "\($0) ms" },
                    get: { DiskLightSettings.durations.firstIndex(of: app.diskSettings.durationMs) ?? 2 },
                    set: { app.diskSettings.durationMs = DiskLightSettings.durations[$0]; app.applySettings() })
            p.header("Drives")
            let t = DiskDrivesTable(monitor: app.disk, settings: app.diskSettings) { app.applySettings() }
            self.drivesTable = t
            p.custom(t.makeScrollView(), height: 200) { t.reload() }
            p.note("USB flash drives and SD cards appear here when plugged in. Hover a light for volumes, free space and read/write speed.")
        })

        // Eyes
        list.append(Pane(title: "Eyes", symbol: "eyes") { p in
            p.header("Googly Eyes")
            p.check("Show googly eyes that follow the mouse", get: { Prefs.showEyes }, set: { Prefs.showEyes = $0; app.applySettings() })
            p.popup("Size", items: Prefs.sizeNames, get: { Prefs.eyeSize }, set: { Prefs.eyeSize = $0; app.applySettings() })
            p.check("Single eye (cyclops)", get: { Prefs.singleEye }, set: { Prefs.singleEye = $0; app.applySettings() })
            p.header("Behavior")
            p.check("Googly wobble", get: { Prefs.googly }, set: { Prefs.googly = $0; app.applySettings() })
            p.check("Blink now and then", get: { Prefs.eyeBlink }, set: { Prefs.eyeBlink = $0; app.applySettings() })
            p.check("Allow cross-eyed (each eye follows the pointer on its own)", get: { Prefs.allowCrossEye },
                    set: { Prefs.allowCrossEye = $0; app.applySettings() },
                    enabled: { !Prefs.singleEye })
            p.check("Lazy (they take their time following the pointer)", get: { Prefs.lazyEyes }, set: { Prefs.lazyEyes = $0; app.applySettings() })
            p.header("Looks")
            p.check("Bloodshot", get: { Prefs.bloodshot }, set: { Prefs.bloodshot = $0; app.applySettings() })
            p.check("Bloodshot while keeping the Mac awake", get: { Prefs.bloodshotAwake }, set: { Prefs.bloodshotAwake = $0; app.applySettings() })
            p.check("Pirate eyepatch", get: { Prefs.pirate }, set: { Prefs.pirate = $0; app.applySettings() },
                    enabled: { !Prefs.singleEye })
            p.popup("Lashes", items: ["None", "Natural", "Fake"], get: { Prefs.lashes }, set: { Prefs.lashes = $0; app.applySettings() })
            p.header("Emotions")
            // one box, two columns: each mood is set off by something the Mac is doing (hover a name to see what)
            let all = Emotion.allCases
            var moodBoxes: [NSButton] = []
            for (i, e) in all.enumerated() {
                let b = HoverCheckbox(checkboxWithTitle: e.title, target: nil, action: nil)
                b.toolTip = e.when
                b.onHover = { on in app.previewEmotion(e, on) }       // hover a name to see the eyes do it
                b.widthAnchor.constraint(equalToConstant: 200).isActive = true
                b.target = p.actionBox { _ in
                    var off = Prefs.emotionsOff
                    if moodBoxes[i].state == .on { off.remove(e) } else { off.insert(e) }
                    Prefs.emotionsOff = off
                    app.applySettings()
                }
                b.action = #selector(ActionBox.run(_:))
                moodBoxes.append(b)
            }
            let half = (all.count + 1) / 2
            for k in 0..<half {
                var cells: [NSView] = [moodBoxes[k]]
                if k + half < all.count { cells.append(moodBoxes[k + half]) }
                p.addRow(p.row(cells))
            }
            p.addRow(NSView(), onRefresh: {
                let off = Prefs.emotionsOff
                for (i, e) in all.enumerated() { moodBoxes[i].state = off.contains(e) ? .off : .on; moodBoxes[i].isEnabled = Prefs.showEyes }
            })
            p.note("Sleepy when idle, alarmed or angry when the CPU is slammed, sweating when hot, happy on the charger, sad with no network, suspicious of a lingering pointer, a one-eye skeptical squint when you whip the pointer around, startled by a new drive, bored now and then — and hearts for a tip. Hover over a name to see the eyes do it (and when it shows).")
            p.footnote("Click the eyes to open the About window. Circle the pointer over them two and a half times to spin them. On a MacBook with a motion sensor, shake the Mac to make them dizzy. A tribute to the classic desktop toys that kept an eye on your cursor.")
        })

        #if !APPSTORE
        // Screen saver
        list.append(Pane(title: "Screen Saver", symbol: "airplane") { p in
            var current = BundledSaver.all[min(SettingsWindow.initialSaver, BundledSaver.all.count - 1)]
            var o: SaverOptions { SaverConfig.options(for: current.scene) }
            func change(_ f: (inout SaverOptions) -> Void) {
                var x = SaverConfig.options(for: current.scene); f(&x); SaverConfig.save(x, for: current.scene)
            }
            p.header("Screen Saver")
            p.popup("Screen saver", items: BundledSaver.all.map(\.name), get: { BundledSaver.all.firstIndex { $0.scene == current.scene } ?? 0 },
                    set: { current = BundledSaver.all[$0]; p.refresh() })
            p.label { current.about }
            p.buttons([
                p.makeButton("Preview") { SaverPreviewWindow.shared.show(current) },
                p.makeButton("Install & Show in System Settings") { current.install(); p.refresh() },
            ])
            p.label { current.isInstalled ? "✓ Installed. To use it: System Settings ▸ Wallpaper ▸ Screen Saver, then pick it under Other (at the end)." : "Not installed yet." }
            p.divider()
            p.popup("Hot corner", items: Corner.allCases.map(\.title), get: { Prefs.cornerSaver.rawValue },
                    set: { Prefs.cornerSaver = Corner(rawValue: $0) ?? .none; app.applySettings() })
            p.note("Rest the pointer there to start the screen saver chosen in System Settings. Pick a corner Keep Awake and Sleep now don't use.")

            // Jet Racers: who wins, how they celebrate, and how the race is covered
            let isRace = { current.scene == "jetrace" }, J = JetRaceChoices.self
            func choice(_ label: String, _ list: [JetRaceChoices.Choice], _ key: WritableKeyPath<SaverOptions, String?>) {
                p.popup(label, items: list.map(\.name), get: { J.index(list, o[keyPath: key]) }, set: { i in change { $0[keyPath: key] = list[i].id } })
            }
            p.header("Race", visible: isRace)
            choice("Winner", J.winners, \.winner)
            p.note("Random runs a fair race: any of the three can win. Pick a racer and every race is one that racer wins.")
            choice("Celebration", J.celebrations, \.celebration)
            p.note("After the finish the winner spins out, then celebrates. Random picks a different celebration each race.")
            p.header("Coverage", visible: isRace)
            choice("Camera", J.cameras, \.camera)
            choice("Follow", J.follows, \.follow)
            p.check("Leaderboard", get: { o.board ?? true }, set: { v in change { $0.board = v } })
            p.check("Camera captions", get: { o.captions ?? false }, set: { v in change { $0.captions = v } })

            p.header("Flight", visible: { !isRace() })
            // the choice boxes are liveries (Flying Cars) or satellites (Starlink); Starships has none
            let maxChoices = BundledSaver.all.map(\.choices.count).max() ?? 0
            let boxes = (0..<maxChoices).map { _ in NSButton(checkboxWithTitle: "", target: nil, action: nil) }
            let choiceLabel = NSTextField(labelWithString: "")
            choiceLabel.widthAnchor.constraint(equalToConstant: 124).isActive = true
            for (i, b) in boxes.enumerated() {
                b.target = p.actionBox { _ in
                    let ids = current.choices.map(\.id)
                    guard i < ids.count else { return }
                    change { x in
                        var on = Set(x.liveries)
                        if boxes[i].state == .on { on.insert(ids[i]) } else { on.remove(ids[i]) }
                        if on.isEmpty { on.insert(ids[i]); boxes[i].state = .on }   // keep at least one
                        x.liveries = ids.filter(on.contains)
                    }
                }
                b.action = #selector(ActionBox.run(_:))
            }
            let choiceRow = p.row([choiceLabel] + boxes)
            p.addRow(choiceRow, onRefresh: {
                let ch = current.choices
                choiceRow.isHidden = ch.isEmpty
                choiceLabel.stringValue = current.scene == "starlink" ? "Satellites" : "Liveries"
                for (i, b) in boxes.enumerated() {
                    b.isHidden = i >= ch.count
                    if i < ch.count {
                        b.title = ch[i].name.replacingOccurrences(of: "Starlink ", with: "")
                        b.state = o.liveries.contains(ch[i].id) ? .on : .off
                    }
                }
            })
            let times: (Double) -> String = { String(format: "%.1f×", $0) }
            p.slider("How many", min: 1, max: 16, get: { Double(min(o.count, 16)) }, set: { v in change { $0.count = Int(v.rounded()) } },
                     value: { String(Int($0.rounded())) }, visible: { current.scene != "starlink" })
            p.slider("How many", min: 1, max: 69, get: { Double(o.count) }, set: { v in change { $0.count = Int(v.rounded()) } },
                     value: { String(Int($0.rounded())) }, caption: "up to 69 satellites",
                     visible: { current.scene == "starlink" })
            p.slider("Speed", min: 0.3, max: 3, get: { o.speed }, set: { v in change { $0.speed = v } }, value: times)
            p.slider("Flap speed", min: 0.2, max: 3, get: { o.flapSpeed }, set: { v in change { $0.flapSpeed = v } },
                     value: times, caption: "flaps, wings, fans, wheels")
            p.slider("Roll angle", min: -90, max: 90, get: { o.tilt ?? SaverConfig.defaultTilt(for: current.scene) },
                     set: { v in change { $0.tilt = (v / 2).rounded() * 2 } }, value: { String(format: "%.0f°", $0) },
                     caption: "how far each craft is rolled toward you",
                     trailing: p.makeButton("Default") { change { $0.tilt = nil }; p.refresh() })
            p.slider("Flock angle", min: 0, max: 360, get: { o.heading ?? SaverConfig.defaultHeading },
                     set: { v in change { $0.heading = v.rounded() } }, value: { SaverConfig.headingText($0) },
                     caption: "the direction they fly across the screen",
                     trailing: p.makeButton("Default") { change { $0.heading = nil }; p.refresh() })
            p.check("Stunts (barrel rolls, veers, climbs and dives)", get: { o.stunts }, set: { v in change { $0.stunts = v } })

            p.header("Scene", visible: { !isRace() })
            p.slider("Oxidation", min: 0, max: 1, get: { o.oxidation }, set: { v in change { $0.oxidation = v } },
                     value: { String(format: "%.0f%%", $0 * 100) }, caption: "fresh tiles → after re-entry",
                     visible: { current.scene == "starships" })
            p.check("Crossing orbits (strings of satellites in an X pattern)", get: { o.crossing ?? true },
                    set: { v in change { $0.crossing = v } }, visible: { current.scene == "starlink" })
            p.check("Laser links between nearby satellites", get: { o.lasers ?? true },
                    set: { v in change { $0.lasers = v } }, visible: { current.scene == "starlink" })
            p.check("Roadster with Starman", get: { o.roadster ?? true },
                    set: { v in change { $0.roadster = v }; p.refresh() }, visible: { current.scene == "starships" })
            p.check("Stabilized (flies level with the ships instead of tumbling)", indent: true,
                    get: { o.roadsterStable ?? false }, set: { v in change { $0.roadsterStable = v } },
                    enabled: { o.roadster ?? true }, visible: { current.scene == "starships" })
            p.check("Close encounter (now and then a ship flaps by right in front of you)", get: { o.closeEncounter ?? false },
                    set: { v in change { $0.closeEncounter = v } }, visible: { current.scene == "starships" })
            p.check("Clouds (a blue daytime sky)", get: { o.clouds ?? false },
                    set: { v in change { $0.clouds = v }; p.refresh() }, visible: { current.scene == "cars" })
            p.check("Stars in the background", get: { o.stars }, set: { v in change { $0.stars = v } },
                    enabled: { !(current.scene == "cars" && (o.clouds ?? false)) })
            p.footnote("Changes apply the next time the screen saver starts, and in Preview. Not affiliated with SpaceX; the X1 SkyRacer, its liveries and the Starship come from the X1 SkyRacer Flying Car Race Sim.")
        })

        // Scrolling
        list.append(Pane(title: "Scrolling", symbol: "computermouse") { p in
            p.header("Mouse Scrolling")
            p.check("Reverse mouse scrolling", get: { Prefs.reverseScroll }, set: { app.setReverseScroll($0) })
            p.check("Include trackpad / Magic Mouse", indent: true, get: { Prefs.reverseTrackpad }, set: { app.setReverseTrackpad($0) })
            p.check("Include horizontal scrolling", indent: true, get: { Prefs.reverseHorizontal }, set: { app.setReverseHorizontal($0) })
            p.header("Permission")
            p.label {
                ScrollReverser.hasPermission ? "✓ Accessibility permission granted"
                                             : "Needs Accessibility permission (Privacy & Security ▸ Accessibility)"
            }
            p.button("Show Me Where to Turn It On…") { PermissionGuide.shared.show() }
        })
        #endif

        return list
    }
}
