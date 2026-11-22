import AppKit

/// Settings for disk activity LEDs: enable per drive, LED color per drive, blink duration.
final class DiskLightSettings {
    static let durations: [Int] = [10, 20, 35, 50, 75, 100, 150, 250, 500]
    private let d = UserDefaults.standard

    var showDisks: Bool {
        get { d.object(forKey: "showDisks") as? Bool ?? true }
        set { d.set(newValue, forKey: "showDisks") }
    }
    /// 0 = small, 1 = medium, 2 = large
    var ledSize: Int {
        get { min(max(d.integer(forKey: "ledSize"), 0), 2) }
        set { d.set(newValue, forKey: "ledSize") }
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

/// The per-drive table (enable checkbox, name, LED color) used in Settings ▸ Disks.
final class DiskDrivesTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let monitor: DiskMonitor
    private let settings: DiskLightSettings
    private let onChange: () -> Void
    let table = NSTableView()

    init(monitor: DiskMonitor, settings: DiskLightSettings, onChange: @escaping () -> Void) {
        self.monitor = monitor
        self.settings = settings
        self.onChange = onChange
        super.init()
        let cOn = NSTableColumn(identifier: .init("on")); cOn.title = ""; cOn.width = 36; cOn.minWidth = 36; cOn.maxWidth = 36
        let cDrive = NSTableColumn(identifier: .init("drive")); cDrive.title = "Drive"; cDrive.width = 330
        let cLED = NSTableColumn(identifier: .init("led")); cLED.title = "LED"; cLED.width = 110
        [cOn, cDrive, cLED].forEach(table.addTableColumn)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
    }

    func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        return scroll
    }

    func reload() { table.reloadData() }

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
}
