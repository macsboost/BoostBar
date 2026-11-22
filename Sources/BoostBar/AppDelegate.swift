import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let graphView = StatusGraphView(frame: .zero)
    private let net = NetworkMonitor(capacity: 30)
    private let scroll = ScrollReverser()
    private let sleep = SleepManager()
    private let updater = Updater()
    private let defaults = UserDefaults.standard
    private var lidSleepDisabled = false
    private var battery: BatteryReading?
    private var batteryHistory = History(capacity: 600)   // watts, 10 min at 1 Hz
    private var lastLayoutKey = ""

    private let disk = DiskMonitor()
    private let diskSettings = DiskLightSettings()
    private var diskWindow: DiskLightsWindow?

    private var hoverTarget: StatusGraphView.Target?
    private var hoverTimer: Timer?
    private var menuIsOpen = false
    private var colorPanelKey: String?

    private enum Key {
        static let reverseScroll = "reverseScroll"
        static let reverseTrackpad = "reverseTrackpad"
        static let reverseHorizontal = "reverseHorizontal"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let useBits = "useBits"
        static let checkOnLaunch = "checkUpdatesOnLaunch"
        static let lidWarningShown = "lidWarningShown"
        static let showNetwork = "showNetwork"
        static let showBattery = "showBattery"
        static let upColor = "netUpColor"
        static let downColor = "netDownColor"
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Key.reverseScroll: false,
            Key.reverseTrackpad: false,
            Key.reverseHorizontal: false,
            Key.keepDisplayAwake: false,
            Key.useBits: false,
            Key.checkOnLaunch: true,
            Key.showNetwork: true,
            Key.showBattery: BatteryMonitor.hasBattery,
            Key.upColor: "White",
            Key.downColor: "White",
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            graphView.frame = button.bounds
            graphView.autoresizingMask = [.width, .height]
            button.addSubview(graphView)
            button.setAccessibilityLabel("BoostBar")
        }
        graphView.onHover = { [weak self] t in self?.hoverChanged(t) }
        graphView.onExit = { [weak self] in self?.hideHover() }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        scroll.reverseTrackpad = defaults.bool(forKey: Key.reverseTrackpad)
        scroll.reverseHorizontal = defaults.bool(forKey: Key.reverseHorizontal)
        scroll.onNeedsPermission = { [weak self] in
            guard let self, self.defaults.bool(forKey: Key.reverseScroll) else { return }
            PermissionGuide.shared.show()
        }
        scroll.onStateChange = { if ScrollReverser.hasPermission { PermissionGuide.shared.close() } }
        if defaults.bool(forKey: Key.reverseScroll) { scroll.start() }

        sleep.keepDisplayAwake = defaults.bool(forKey: Key.keepDisplayAwake)
        sleep.onChange = { [weak self] in self?.refreshStatus() }

        lidSleepDisabled = LidSleep.isDisabled

        disk.onLEDChange = { [weak self] in
            guard let self else { return }
            self.graphView.litKeys = self.disk.lit
            self.graphView.needsDisplay = true
        }
        disk.onDrivesChanged = { [weak self] in
            self?.applyDiskSettings()
            self?.diskWindow?.reload()
        }
        disk.start()
        applyDiskSettings()

        net.onUpdate = { [weak self] in self?.tick() }
        net.start()

        if defaults.bool(forKey: Key.checkOnLaunch) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updater.check(userInitiated: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleep.allow()
        scroll.stop()
    }

    // MARK: - Status item

    /// Once per second: sample battery history, redraw, and refresh an open hover panel.
    private func tick() {
        if BatteryMonitor.hasBattery, let b = BatteryMonitor.read() {
            batteryHistory.append(b.watts)
        }
        refreshStatus()
        if HoverPanel.shared.isVisible, let t = hoverTarget, let c = hoverContent(for: t) {
            HoverPanel.shared.update(c)
        }
    }

    private func applyDiskSettings() {
        disk.ledDurationMs = Double(diskSettings.durationMs)
        disk.enabledKeys = Set(disk.drives.filter { diskSettings.isEnabled($0) }.map(\.key))
        disk.isActive = diskSettings.showDisks
        if statusItem != nil { refreshStatus() }
    }

    private var upColor: NSColor { Palette.resolve(defaults.string(forKey: Key.upColor), default: .white) }
    private var downColor: NSColor { Palette.resolve(defaults.string(forKey: Key.downColor), default: .white) }

    private func refreshStatus() {
        let bits = defaults.bool(forKey: Key.useBits)
        battery = BatteryMonitor.hasBattery ? BatteryMonitor.read() : nil

        graphView.showNetwork = defaults.bool(forKey: Key.showNetwork)
        graphView.showBattery = defaults.bool(forKey: Key.showBattery)
        graphView.showDisks = diskSettings.showDisks
        graphView.upColor = upColor
        graphView.downColor = downColor
        graphView.battery = battery
        graphView.up = net.upHistory
        graphView.down = net.downHistory
        graphView.upText = NetworkMonitor.format(net.currentUp, bits: bits)
        graphView.downText = NetworkMonitor.format(net.currentDown, bits: bits)
        graphView.leds = disk.drives.filter { diskSettings.isEnabled($0) }
            .map { StatusGraphView.LED(key: $0.key, color: diskSettings.color($0)) }
        graphView.litKeys = disk.lit
        graphView.awake = lidSleepDisabled ? .lidAwake : (sleep.isPreventing ? .keepAwake : .normal)

        let h = statusItem.button?.bounds.height ?? NSStatusBar.system.thickness
        let width = graphView.layoutSegments(height: h)
        let layoutKey = "\(width)|\(graphView.networkRect)|\(graphView.batteryRect)|\(graphView.diskRect)"
        if layoutKey != lastLayoutKey {
            lastLayoutKey = layoutKey
            statusItem.length = width
            statusItem.button?.toolTip = nil
        }
        graphView.needsDisplay = true
    }

    // MARK: - Hover panel

    private func hoverChanged(_ t: StatusGraphView.Target?) {
        guard t != hoverTarget else { return }
        hoverTarget = t
        hoverTimer?.invalidate()
        guard let t else {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.hideHover() }
            return
        }
        if HoverPanel.shared.isVisible {
            showHover(t)
        } else {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.showHover(t) }
        }
    }

    private func showHover(_ t: StatusGraphView.Target) {
        guard !menuIsOpen, hoverTarget == t, let c = hoverContent(for: t), let anchor = graphView.screenRect(for: t) else { return }
        HoverPanel.shared.show(c, below: anchor)
    }

    private func hideHover() {
        hoverTimer?.invalidate()
        hoverTarget = nil
        HoverPanel.shared.hide()
    }

    private func hoverContent(for t: StatusGraphView.Target) -> HoverContent? {
        let bits = defaults.bool(forKey: Key.useBits)
        let rate: (Double) -> String = { NetworkMonitor.format($0, bits: bits) }
        switch t {
        case .network:
            let sent = net.longUp.values.reduce(0, +), received = net.longDown.values.reduce(0, +)
            var lines = [
                "Upload \(rate(net.currentUp))  ·  Download \(rate(net.currentDown))",
                "Last 5 min: \(DiskMonitor.formatBytes(Int64(sent))) sent · \(DiskMonitor.formatBytes(Int64(received))) received",
            ]
            if lidSleepDisabled { lines.append("Sleep disabled (incl. lid closed)") }
            else if sleep.isPreventing { lines.append("Keeping Mac awake") }
            return HoverContent(
                title: "Network",
                lines: lines,
                top: .init(label: "Upload", values: net.longUp.values, color: upColor, format: rate),
                bottom: .init(label: "Download", values: net.longDown.values, color: downColor, format: rate),
                timespan: "last 5 min")

        case .battery:
            guard let b = battery ?? BatteryMonitor.read() else { return nil }
            let watts: (Double) -> String = { BatteryMonitor.formatWatts($0) }
            let vals = batteryHistory.values
            return HoverContent(
                title: "Battery" + (b.percent.map { " — \($0)%" } ?? ""),
                lines: BatteryMonitor.describe(b).split(separator: "\n").map(String.init),
                top: .init(label: "Charging", values: vals.map { max($0, 0) }, color: StatusGraphView.chargeColor, format: watts),
                bottom: .init(label: "Discharging", values: vals.map { max(-$0, 0) }, color: StatusGraphView.dischargeColor, format: watts),
                timespan: "last 10 min")

        case .disk(let key):
            guard let d = disk.drives.first(where: { $0.key == key }) else { return nil }
            let r = disk.readHistory[key] ?? History(capacity: 60)
            let w = disk.writeHistory[key] ?? History(capacity: 60)
            let diskRate: (Double) -> String = { NetworkMonitor.format($0, bits: false) }
            var lines = ["\(d.bsd)  ·  \(d.kind)  ·  \(DiskMonitor.formatBytes(d.size))"]
            let vols = disk.volumes(on: d)
            if vols.isEmpty {
                lines.append("No mounted volumes")
            } else {
                for v in vols.prefix(4) {
                    lines.append("\(v.name) (\(v.mountPoint)) — \(DiskMonitor.formatBytes(v.available)) free of \(DiskMonitor.formatBytes(v.total))")
                }
            }
            lines.append("Last second: read \(diskRate(r.last)) · write \(diskRate(w.last))")
            return HoverContent(
                title: d.name,
                lines: lines,
                top: .init(label: "Read", values: r.values, color: diskSettings.color(d), format: diskRate),
                bottom: .init(label: "Write", values: w.values, color: .systemPink, format: diskRate),
                timespan: "last 60 s")
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        hideHover()
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        lidSleepDisabled = LidSleep.isDisabled
        refreshStatus()
        menu.removeAllItems()

        let header = NSMenuItem(title: "BoostBar \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let bits = defaults.bool(forKey: Key.useBits)
        let live = NSMenuItem(title: "▲ \(NetworkMonitor.format(net.currentUp, bits: bits))    ▼ \(NetworkMonitor.format(net.currentDown, bits: bits))", action: nil, keyEquivalent: "")
        live.isEnabled = false
        menu.addItem(live)
        if let b = battery {
            for line in BatteryMonitor.describe(b).split(separator: "\n") {
                let i = NSMenuItem(title: String(line), action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
        }

        // Menu bar readouts
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Menu Bar"))
        menu.addItem(item("Show Network Speed", #selector(toggleShowNetwork), on: defaults.bool(forKey: Key.showNetwork)))
        let batItem = item(BatteryMonitor.hasBattery ? "Show Battery Power (W in/out)" : "Show Battery Power (no battery)",
                           #selector(toggleShowBattery), on: BatteryMonitor.hasBattery && defaults.bool(forKey: Key.showBattery))
        batItem.isEnabled = BatteryMonitor.hasBattery
        menu.addItem(batItem)
        menu.addItem(item("Show Disk Lights", #selector(toggleShowDisks), on: diskSettings.showDisks))
        menu.addItem(item("Disk Lights…", #selector(openDiskLights), on: false, key: "d", indent: 1))

        // Sleep
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Sleep"))
        var awakeTitle = "Keep Mac Awake"
        if let until = sleep.until {
            awakeTitle += " (until \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)))"
        }
        menu.addItem(item(awakeTitle, #selector(toggleKeepAwake), on: sleep.isPreventing, key: "k"))

        let forItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, minutes) in [("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480)] {
            let i = item(label, #selector(keepAwakeFor(_:)), on: false)
            i.representedObject = minutes
            sub.addItem(i)
        }
        forItem.submenu = sub
        menu.addItem(forItem)
        menu.addItem(item("Keep Display On Too", #selector(toggleDisplayAwake), on: sleep.keepDisplayAwake, indent: 1))
        menu.addItem(item("Stay Awake With Lid Closed", #selector(toggleLidSleep), on: lidSleepDisabled, key: "l"))
        menu.addItem(item("Lid Toggle Without Password", #selector(toggleLidHelper), on: LidSleep.helperInstalled, indent: 1))

        // Scrolling
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Scrolling"))
        let reverseOn = defaults.bool(forKey: Key.reverseScroll)
        menu.addItem(item("Reverse Mouse Scrolling", #selector(toggleReverseScroll), on: reverseOn, key: "r"))
        if reverseOn && !scroll.isRunning {
            menu.addItem(item("⚠︎ Grant Accessibility Permission…", #selector(openAccessibility), on: false, indent: 1))
        }
        menu.addItem(item("Include Trackpad / Magic Mouse", #selector(toggleReverseTrackpad), on: scroll.reverseTrackpad, indent: 1))
        menu.addItem(item("Include Horizontal Scrolling", #selector(toggleReverseHorizontal), on: scroll.reverseHorizontal, indent: 1))

        // Network
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Network"))
        menu.addItem(item("Show Bits per Second (Kb/s)", #selector(toggleBits), on: bits))
        menu.addItem(colorMenu(title: "Upload Color", key: Key.upColor))
        menu.addItem(colorMenu(title: "Download Color", key: Key.downColor))

        // App
        menu.addItem(.separator())
        var loginTitle = "Launch at Login"
        if LoginItem.needsApproval { loginTitle += " (approve in System Settings)" }
        menu.addItem(item(loginTitle, #selector(toggleLaunchAtLogin), on: LoginItem.isEnabled))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates), on: false, key: "u"))
        menu.addItem(item("Check for Updates at Launch", #selector(toggleCheckOnLaunch), on: defaults.bool(forKey: Key.checkOnLaunch), indent: 1))
        menu.addItem(item("BoostBar on GitHub", #selector(openGitHub), on: false))
        menu.addItem(.separator())
        menu.addItem(item("Quit BoostBar", #selector(quit), on: false, key: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool, key: String = "", indent: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = on ? .on : .off
        i.indentationLevel = indent
        return i
    }

    private func colorMenu(title: String, key: String) -> NSMenuItem {
        let current = defaults.string(forKey: key) ?? "White"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = swatch(Palette.resolve(current, default: .white))
        let sub = NSMenu()
        for entry in Palette.named {
            let i = item(entry.name, #selector(pickPresetColor(_:)), on: current == entry.name)
            i.representedObject = [key, entry.name]
            i.image = swatch(entry.color)
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let custom = item("Custom…", #selector(pickCustomColor(_:)), on: Palette.color(named: current) == nil)
        custom.representedObject = key
        sub.addItem(custom)
        parent.submenu = sub
        return parent
    }

    private func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.setFill()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            p.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            p.lineWidth = 0.5
            p.stroke()
            return true
        }
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        i.isEnabled = false
        return i
    }

    // MARK: - Actions: sleep

    @objc private func toggleKeepAwake() {
        sleep.isPreventing ? sleep.allow() : sleep.prevent(for: nil)
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        sleep.prevent(for: TimeInterval(minutes * 60))
    }

    @objc private func toggleDisplayAwake() {
        sleep.keepDisplayAwake.toggle()
        defaults.set(sleep.keepDisplayAwake, forKey: Key.keepDisplayAwake)
    }

    @objc private func toggleLidSleep() {
        let disable = !LidSleep.isDisabled
        if disable && !defaults.bool(forKey: Key.lidWarningShown) {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Stay awake with the lid closed?"
            a.informativeText = """
            This runs “pmset -a disablesleep 1”: your Mac won’t sleep at all — including when the lid \
            is closed — until you turn it off here. It stays in effect after quitting or restarting.

            Don’t put a running Mac in a bag with this on; it can overheat and drain the battery.

            macOS will ask for your admin password (turn on “Lid Toggle Without Password” to skip that).
            """
            a.addButton(withTitle: "Disable Sleep")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            defaults.set(true, forKey: Key.lidWarningShown)
        }
        LidSleep.set(disabled: disable)
        lidSleepDisabled = LidSleep.isDisabled
        refreshStatus()
    }

    @objc private func toggleLidHelper() {
        let ok = LidSleep.helperInstalled ? LidSleep.removeHelper() : LidSleep.installHelper()
        if !ok {
            Updater.alert("Couldn't change the password-free rule", "The admin request was cancelled or failed.")
        }
    }

    // MARK: - Actions: scrolling

    @objc private func toggleReverseScroll() {
        let on = !defaults.bool(forKey: Key.reverseScroll)
        defaults.set(on, forKey: Key.reverseScroll)
        on ? scroll.start() : scroll.stop()
    }

    @objc private func toggleReverseTrackpad() {
        scroll.reverseTrackpad.toggle()
        defaults.set(scroll.reverseTrackpad, forKey: Key.reverseTrackpad)
    }

    @objc private func toggleReverseHorizontal() {
        scroll.reverseHorizontal.toggle()
        defaults.set(scroll.reverseHorizontal, forKey: Key.reverseHorizontal)
    }

    @objc private func openAccessibility() {
        PermissionGuide.shared.show()
    }

    // MARK: - Actions: misc

    @objc private func toggleShowNetwork() {
        defaults.set(!defaults.bool(forKey: Key.showNetwork), forKey: Key.showNetwork)
        refreshStatus()
    }

    @objc private func toggleShowBattery() {
        defaults.set(!defaults.bool(forKey: Key.showBattery), forKey: Key.showBattery)
        refreshStatus()
    }

    @objc private func toggleShowDisks() {
        diskSettings.showDisks.toggle()
        applyDiskSettings()
        diskWindow?.reload()
    }

    @objc private func openDiskLights() {
        if diskWindow == nil {
            diskWindow = DiskLightsWindow(monitor: disk, settings: diskSettings) { [weak self] in self?.applyDiskSettings() }
        }
        diskWindow?.show()
    }

    @objc private func pickPresetColor(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        defaults.set(pair[1], forKey: pair[0])
        refreshStatus()
    }

    @objc private func pickCustomColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        colorPanelKey = key
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = Palette.resolve(defaults.string(forKey: key), default: .white)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.title = key == Key.upColor ? "Upload Color" : "Download Color"
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let key = colorPanelKey else { return }
        defaults.set(sender.color.hexString, forKey: key)
        refreshStatus()
    }

    @objc private func toggleBits() {
        defaults.set(!defaults.bool(forKey: Key.useBits), forKey: Key.useBits)
        refreshStatus()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
            if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            Updater.alert("Couldn't change Launch at Login",
                          "\(error.localizedDescription)\n\nTip: move BoostBar.app into /Applications first.")
        }
    }

    @objc private func checkForUpdates() { updater.check(userInitiated: true) }

    @objc private func toggleCheckOnLaunch() {
        defaults.set(!defaults.bool(forKey: Key.checkOnLaunch), forKey: Key.checkOnLaunch)
    }

    @objc private func openGitHub() { NSWorkspace.shared.open(Updater.repoPage) }

    @objc private func quit() { NSApp.terminate(nil) }
}
