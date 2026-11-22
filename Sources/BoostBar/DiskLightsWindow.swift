import AppKit

/// Settings for disk activity LEDs: enable per drive, LED color per drive, blink duration.
final class DiskLightSettings {
    static let durations: [Int] = [10, 20, 35, 50, 75, 100, 150, 250, 500]
    private let d = UserDefaults.standard

    var showDisks: Bool {
        get { d.object(forKey: "showDisks") as? Bool ?? true }
        set { d.set(newValue, forKey: "showDisks") }
    }
    var durationMs: Int {
        get { d.object(forKey: "ledDurationMs") as? Int ?? 35 }
        set { d.set(newValue, forKey: "ledDurationMs") }
    }
    private var enabledMap: [String: Bool] {
        get { d.dictionary(forKey: "diskEnabled") as? [String: Bool] ?? [:] }
        set { d.set(newValue, forKey: "diskEnabled") }
    }
    private var colorMap: [String: String] {
        get { d.dictionary(forKey: "diskColor") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "diskColor") }
    }

    /// New drives (including USB flash drives) default to ON.
    func isEnabled(_ drive: DiskMonitor.Drive) -> Bool { enabledMap[drive.key] ?? true }
    func setEnabled(_ on: Bool, for drive: DiskMonitor.Drive) { var m = enabledMap; m[drive.key] = on; enabledMap = m }

    func colorName(_ drive: DiskMonitor.Drive) -> String {
        colorMap[drive.key] ?? (drive.isInternal ? "Green" : "Blue")
    }
    func setColorName(_ name: String, for drive: DiskMonitor.Drive) { var m = colorMap; m[drive.key] = name; colorMap = m }
    func color(_ drive: DiskMonitor.Drive) -> NSColor { Palette.resolve(colorName(drive), default: .systemGreen) }
}

final class DiskLightsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let monitor: DiskMonitor
    private let settings: DiskLightSettings
    private let onChange: () -> Void
    private var window: NSWindow?
    private let table = NSTableView()
    private let durationPopup = NSPopUpButton()
    private let showToggle = NSButton(checkboxWithTitle: "Show disk lights in the menu bar", target: nil, action: nil)

    init(monitor: DiskMonitor, settings: DiskLightSettings, onChange: @escaping () -> Void) {
        self.monitor = monitor
        self.settings = settings
        self.onChange = onChange
    }

    func show() {
        let w = window ?? makeWindow()
        window = w
        reload()
        NSApp.activate(ignoringOtherApps: true)
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    func reload() {
        guard window != nil else { return }
        table.reloadData()
        showToggle.state = settings.showDisks ? .on : .off
        let ms = settings.durationMs
        if let idx = DiskLightSettings.durations.firstIndex(of: ms) { durationPopup.selectItem(at: idx) }
    }

    private func makeWindow() -> NSWindow {
        let size = NSSize(width: 560, height: 400)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Disk Lights"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: size))

        showToggle.target = self
        showToggle.action = #selector(toggleShow)
        showToggle.frame = NSRect(x: 20, y: size.height - 40, width: 400, height: 22)
        content.addSubview(showToggle)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 64, width: size.width - 40, height: size.height - 64 - 52))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        let cOn = NSTableColumn(identifier: .init("on")); cOn.title = ""; cOn.width = 36; cOn.minWidth = 36; cOn.maxWidth = 36
        let cDrive = NSTableColumn(identifier: .init("drive")); cDrive.title = "Drive"; cDrive.width = 340
        let cLED = NSTableColumn(identifier: .init("led")); cLED.title = "LED"; cLED.width = 110
        [cOn, cDrive, cLED].forEach(table.addTableColumn)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        scroll.documentView = table
        content.addSubview(scroll)

        let durLabel = NSTextField(labelWithString: "LED Duration:")
        durLabel.frame = NSRect(x: 20, y: 22, width: 100, height: 20)
        content.addSubview(durLabel)
        durationPopup.frame = NSRect(x: 118, y: 16, width: 110, height: 28)
        durationPopup.addItems(withTitles: DiskLightSettings.durations.map { "\($0) ms" })
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)
        content.addSubview(durationPopup)

        let note = NSTextField(labelWithString: "USB flash drives and SD cards appear here when plugged in.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 238, y: 22, width: 230, height: 16)
        note.lineBreakMode = .byTruncatingTail
        content.addSubview(note)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.frame = NSRect(x: size.width - 20 - 90, y: 14, width: 90, height: 32)
        content.addSubview(close)

        w.contentView = content
        return w
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { monitor.drives.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < monitor.drives.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let drive = monitor.drives[row]
        switch id {
        case "on":
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleDrive(_:)))
            b.tag = row
            b.state = settings.isEnabled(drive) ? .on : .off
            return centered(b, width: 20)
        case "drive":
            let t = NSTextField(labelWithString: drive.displayName)
            t.lineBreakMode = .byTruncatingMiddle
            t.toolTip = "\(drive.displayName)\n\(drive.kind) · \(DiskMonitor.formatBytes(drive.size))"
            let sub = NSTextField(labelWithString: "\(drive.kind) · \(DiskMonitor.formatBytes(drive.size))")
            sub.font = .systemFont(ofSize: 10)
            sub.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [t, sub])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            return stack
        case "led":
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.controlSize = .small
            for entry in Palette.named {
                p.addItem(withTitle: entry.name)
                p.lastItem?.image = swatch(entry.color)
            }
            p.selectItem(withTitle: settings.colorName(drive))
            p.tag = row
            p.target = self
            p.action = #selector(colorChanged(_:))
            return centered(p, width: 100)
        default:
            return nil
        }
    }

    private func centered(_ v: NSView, width: CGFloat) -> NSView {
        let host = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 4),
            v.widthAnchor.constraint(equalToConstant: width),
        ])
        return host
    }

    private func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    // MARK: Actions

    @objc private func toggleDrive(_ sender: NSButton) {
        guard sender.tag < monitor.drives.count else { return }
        settings.setEnabled(sender.state == .on, for: monitor.drives[sender.tag])
        onChange()
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        guard sender.tag < monitor.drives.count, let name = sender.titleOfSelectedItem else { return }
        settings.setColorName(name, for: monitor.drives[sender.tag])
        onChange()
    }

    @objc private func durationChanged() {
        let i = durationPopup.indexOfSelectedItem
        guard i >= 0, i < DiskLightSettings.durations.count else { return }
        settings.durationMs = DiskLightSettings.durations[i]
        onChange()
    }

    @objc private func toggleShow() {
        settings.showDisks = showToggle.state == .on
        onChange()
    }

    @objc private func closeWindow() { window?.close() }
}
