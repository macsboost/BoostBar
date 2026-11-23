import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let graphView = StatusGraphView(frame: .zero)
    private let net = NetworkMonitor(capacity: 30)
    private let cpu = CPUMonitor()
    /// The CPU meter runs on its own fast clock: load is sampled Prefs.cpuRate times a second and the needle and bars
    /// glide toward each reading at 20 frames a second, redrawing only the meter (and only while something moves).
    /// The damping is automatic: the glide's time constant follows the update rate (slow updates get a long, smooth
    /// sweep; fast ones a quick one), with a floor so the kernel's coarse tick counts don't make the needle jitter.
    private var cpuTimer: Timer?
    private var cpuSince = 1.0
    private var cpuShown = 0.0, cpuCoresShown: [Double] = []

    private func setCPUMeterRunning(_ on: Bool) {
        if !on { cpuTimer?.invalidate(); cpuTimer = nil; return }
        guard cpuTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.cpuStep() }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        cpuTimer = t
    }

    private func cpuStep() {
        let dt = 0.05, rate = Prefs.cpuRate
        cpuSince += dt
        if cpuSince >= 1 / rate - 0.001 { cpuSince = 0; cpu.sample() }
        let k = 1 - exp(-dt / max(0.1, 0.65 / rate))
        var moved = abs(cpu.total - cpuShown) > 0.002
        cpuShown += (cpu.total - cpuShown) * k
        if cpuCoresShown.count != cpu.cores.count { cpuCoresShown = cpu.cores; moved = true }
        for i in cpuCoresShown.indices {
            if abs(cpu.cores[i] - cpuCoresShown[i]) > 0.004 { moved = true }
            cpuCoresShown[i] += (cpu.cores[i] - cpuCoresShown[i]) * k
        }
        guard moved else { return }
        graphView.cpu = cpuShown
        graphView.cpuCores = cpuCoresShown
        graphView.setNeedsDisplay(graphView.cpuRect.insetBy(dx: -1, dy: 0))
    }
    private let eyes = EyesAnimator()
    #if !APPSTORE
    let shake = ShakeDetector()
    #endif
    private let corners = HotCorners()
#if !APPSTORE
    private let scroll = ScrollReverser()
    private let updater = Updater()
#endif
    let sleep = SleepManager()
    let disk = DiskMonitor()
    let diskSettings = DiskLightSettings()
    private(set) var lidSleepDisabled = false

    private var battery: BatteryReading?
    private var batteryHistory = History(capacity: 600)   // watts, 10 min at 1 Hz
    private var lastLayoutKey = ""

    private lazy var settingsWindow = SettingsWindow(app: self)

    private var hoverTarget: StatusGraphView.Target?
    private var hoverTimer: Timer?
    private var menuIsOpen = false
    private let statusMenu = NSMenu()
    private var mouseMonitor: Any?

    static let awakeDurations: [(label: String, minutes: Int?)] = [
        ("Indefinitely", nil), ("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60),
        ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480),
    ]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), i + 1 < CommandLine.arguments.count {
            settingsWindow.snapshot(to: CommandLine.arguments[i + 1])   // layout check: render every Settings tab, then quit
            exit(0)
        }
        #if !APPSTORE
        if MoveToApplications.offerIfNeeded() { return }
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            graphView.frame = button.bounds
            graphView.autoresizingMask = [.width, .height]
            button.addSubview(graphView)
            button.setAccessibilityLabel("BoostBar")
        }
        graphView.onHover = { [weak self] t in self?.hoverChanged(t) }
        graphView.onExit = { [weak self] in self?.hideHover() }
        graphView.onClick = { [weak self] in self?.openMenu() }
        graphView.onEyesClick = { [weak self] in self?.hideHover(); self?.showAbout() }
        graphView.onDragBegan = { [weak self] in self?.hideHover() }
        graphView.onReorder = { [weak self] order in self?.setOrder(order) }
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonDown(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        eyes.view = graphView
        #if !APPSTORE
        shake.onShake = { [weak self] on in self?.eyes.shaking = on }
        #endif
        corners.onCorner = { [weak self] c, screen in self?.hotCorner(c, screen) }

        // The menu is attached only while it's open, so a drag on the bar can reorder pieces instead.
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false

        // Catch mouse-downs on our status item before the status button does, so we can tell a
        // click (open the menu) from a drag (reorder pieces). ⌘-drag is left to macOS.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, let w = self.statusItem.button?.window, e.window === w,
                  !e.modifierFlags.contains(.command), !self.menuIsOpen else { return e }
            self.graphView.trackMouse(from: e)
            return nil
        }

#if !APPSTORE
        scroll.reverseTrackpad = Prefs.reverseTrackpad
        scroll.reverseHorizontal = Prefs.reverseHorizontal
        scroll.onNeedsPermission = {
            guard Prefs.reverseScroll else { return }
            PermissionGuide.shared.show()
        }
        scroll.onStateChange = {
            if ScrollReverser.hasPermission { PermissionGuide.shared.close() }
            NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
        }
        if Prefs.reverseScroll { scroll.start() }
        lidSleepDisabled = LidSleep.isDisabled
#endif

        sleep.keepDisplayAwake = Prefs.keepDisplayAwake
        sleep.onChange = { [weak self] in
            self?.refreshStatus()
            NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
        }

        disk.onLEDChange = { [weak self] in
            guard let self else { return }
            self.graphView.litKeys = self.disk.lit
            self.graphView.needsDisplay = true
        }
        disk.onDrivesChanged = { [weak self] in
            self?.applySettings()
            NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
        }
        disk.start()

        net.onUpdate = { [weak self] in self?.tick() }
        net.start()
        applySettings()

        #if APPSTORE
        TipJar.startObserving()
        #endif
        SupportWindow.shared.showIfFirstLaunch()
        InstallPing.sendIfNeeded()

#if !APPSTORE
        if Prefs.checkOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.updater.check(userInitiated: false)
            }
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleep.allow()
        #if !APPSTORE
        scroll.stop()
        #endif
    }

    // MARK: - Settings

    /// Re-read every preference and apply it to the monitors and the status item.
    func applySettings() {
        disk.ledDurationMs = Double(diskSettings.durationMs)
        disk.enabledKeys = Set(disk.drives.filter { diskSettings.isEnabled($0) }.map(\.key))
        disk.isActive = diskSettings.showDisks

        eyes.googly = Prefs.googly
        eyes.lazy = Prefs.lazyEyes
        eyes.blink = Prefs.eyeBlink
        eyes.allowCrossEye = Prefs.allowCrossEye
        eyes.setRunning(Prefs.showEyes)
        #if !APPSTORE
        if Prefs.showEyes { shake.start() } else { shake.stop() }
        #endif

        var watch: Set<Corner> = [Prefs.cornerAwake]
        #if !APPSTORE
        watch.insert(Prefs.cornerSleep)
        watch.insert(Prefs.cornerSaver)
        #endif
        corners.watched = watch

        if statusItem != nil { refreshStatus() }
    }

    private func hotCorner(_ c: Corner, _ screen: NSScreen) {
        #if !APPSTORE
        if c == Prefs.cornerSaver && c != .none {
            Toast.shared.show("Screen saver…", symbol: "sparkles.tv", near: c, on: screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { BundledSaver.startNow() }
            return
        }
        if c == Prefs.cornerSleep && c != .none {
            Toast.shared.show("Sleeping…", symbol: "moon.zzz.fill", near: c, on: screen)
            sleep.allow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                Shell.run("/usr/bin/pmset", ["sleepnow"])
            }
            return
        }
        #endif
        if c == Prefs.cornerAwake && c != .none {
            toggleKeepAwake()
            Toast.shared.show(sleep.isPreventing ? "Keep Awake ON" : "Keep Awake OFF",
                              symbol: sleep.isPreventing ? "cup.and.saucer.fill" : "moon.fill", near: c, on: screen)
        }
    }

    func keepAwake(minutes: Int?) {
        sleep.prevent(for: minutes.map { TimeInterval($0 * 60) })
    }

    func setKeepDisplayAwake(_ on: Bool) {
        sleep.keepDisplayAwake = on
        Prefs.keepDisplayAwake = on
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

    private func refreshStatus() {
        let bits = Prefs.useBits
        battery = BatteryMonitor.hasBattery ? BatteryMonitor.read() : nil

        if !graphView.isDragging { graphView.order = Prefs.segmentOrder }  // don't yank a piece mid-drag
        graphView.showNetwork = Prefs.showNetwork
        graphView.showBattery = Prefs.showBattery
        graphView.showDisks = diskSettings.showDisks
        graphView.showEyes = Prefs.showEyes
        graphView.showCPU = Prefs.showCPU
        graphView.netUnit = Prefs.netUnit
        graphView.netBits = Prefs.useBits
        graphView.cpuStyle = Prefs.cpuStyle
        if cpuCoresShown.count != cpu.cores.count { cpuCoresShown = cpu.cores }
        graphView.cpu = cpuShown
        graphView.cpuCores = cpuCoresShown
        setCPUMeterRunning(Prefs.showCPU)
        graphView.eyeSize = Prefs.eyeSize
        graphView.singleEye = Prefs.singleEye
        graphView.bloodshot = Prefs.bloodshot || (Prefs.bloodshotAwake && (sleep.isPreventing || lidSleepDisabled))
        graphView.eyesShowAwake = Prefs.bloodshotAwake && !Prefs.bloodshot
        graphView.verticalLabels = Prefs.verticalLabels
        graphView.pirate = Prefs.pirate
        graphView.ledSize = diskSettings.ledSize
        graphView.upColor = Prefs.upColor
        graphView.downColor = Prefs.downColor
        graphView.battery = battery
        graphView.up = net.upHistory
        graphView.down = net.downHistory
        graphView.upText = NetworkMonitor.format(net.currentUp, bits: bits, unit: Prefs.netUnit)
        graphView.downText = NetworkMonitor.format(net.currentDown, bits: bits, unit: Prefs.netUnit)
        let links = Prefs.netSplit ? net.activeLinks : []
        graphView.netRows = links.count >= 2 ? links.map {
            .init(id: $0.id, symbol: $0.symbol, up: $0.up, down: $0.down,
                  upText: NetworkMonitor.format($0.currentUp, bits: bits, unit: Prefs.netUnit), downText: NetworkMonitor.format($0.currentDown, bits: bits, unit: Prefs.netUnit))
        } : []
        graphView.leds = disk.drives.filter { diskSettings.isEnabled($0) }
            .map { StatusGraphView.LED(key: $0.key, color: diskSettings.color($0)) }
        graphView.litKeys = disk.lit
        graphView.awake = lidSleepDisabled ? .lidAwake : (sleep.isPreventing ? .keepAwake : .normal)

        let h = statusItem.button?.bounds.height ?? NSStatusBar.system.thickness
        let width = graphView.layoutSegments(height: h)
        let layoutKey = "\(width)|\(graphView.networkRect)|\(graphView.batteryRect)|\(graphView.diskRect)|\(graphView.eyesRect)|\(graphView.cpuRect)|\(Prefs.netUnit.rawValue)"
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
        let bits = Prefs.useBits
        let rate: (Double) -> String = { NetworkMonitor.format($0, bits: bits) }
        switch t {
        case .network(let id):
            if let id, let l = net.link(id) {
                let sent = l.longUp.values.reduce(0, +), received = l.longDown.values.reduce(0, +)
                var lines = [
                    "Upload \(rate(l.currentUp))  ·  Download \(rate(l.currentDown))",
                    "Last 5 min: \(DiskMonitor.formatBytes(Int64(sent))) sent · \(DiskMonitor.formatBytes(Int64(received))) received",
                    "All connections: ▲ \(rate(net.currentUp))  ▼ \(rate(net.currentDown))",
                ]
                if l.kind == .wifi, let w = WiFiInfo.shared.line(for: l.id) { lines.insert(w, at: 0) }
                return HoverContent(
                    title: "\(l.short) — \(l.name) (\(l.id))",
                    lines: lines,
                    top: .init(label: "Upload", values: l.longUp.values, color: Prefs.upColor, format: rate),
                    bottom: .init(label: "Download", values: l.longDown.values, color: Prefs.downColor, format: rate),
                    timespan: "last 5 min")
            }
            let sent = net.longUp.values.reduce(0, +), received = net.longDown.values.reduce(0, +)
            var lines = [
                "Upload \(rate(net.currentUp))  ·  Download \(rate(net.currentDown))",
                "Last 5 min: \(DiskMonitor.formatBytes(Int64(sent))) sent · \(DiskMonitor.formatBytes(Int64(received))) received",
            ]
            let active = net.activeLinks
            if let wifi = active.first(where: { $0.kind == .wifi }), let w = WiFiInfo.shared.line(for: wifi.id) {
                lines.insert(active.count > 1 ? w.replacingOccurrences(of: "Network: ", with: "Wi‑Fi network: ") : w, at: 0)
            }
            if active.count > 1 {
                for l in active { lines.append("\(l.short): ▲ \(rate(l.currentUp))  ▼ \(rate(l.currentDown))") }
            }
            if lidSleepDisabled { lines.append("Sleep disabled (incl. lid closed)") }
            else if sleep.isPreventing { lines.append("Keeping Mac awake") }
            return HoverContent(
                title: "Network",
                lines: lines,
                top: .init(label: "Upload", values: net.longUp.values, color: Prefs.upColor, format: rate),
                bottom: .init(label: "Download", values: net.longDown.values, color: Prefs.downColor, format: rate),
                timespan: "last 5 min")

        case .battery:
            guard let b = battery ?? BatteryMonitor.read() else { return nil }
            let watts: (Double) -> String = { BatteryMonitor.formatWatts($0) }
            let vals = batteryHistory.values
            var lines = BatteryMonitor.describe(b).split(separator: "\n").map(String.init)
            var health: [String] = []
            if let c = b.cycleCount { health.append("Cycle count: \(c)") }
            if let h = b.healthPercent { health.append("Health: \(h)% of original capacity") }
            if !health.isEmpty { lines.append(health.joined(separator: "  ·  ")) }
            return HoverContent(
                title: "Battery" + (b.percent.map { " — \($0)%" } ?? ""),
                lines: lines,
                top: .init(label: "Charging", values: vals.map { max($0, 0) }, color: StatusGraphView.chargeColor, format: watts),
                bottom: .init(label: "Discharging", values: vals.map { max(-$0, 0) }, color: StatusGraphView.dischargeColor, format: watts),
                timespan: "last 10 min")

        case .cpu:
            let pct: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
            var lines = ["User \(pct(cpu.user))  ·  System \(pct(cpu.system))  ·  \(cpu.cores.count) cores"]
            if !cpu.cores.isEmpty {
                let busiest = cpu.cores.enumerated().max { $0.element < $1.element }!
                lines.append("Busiest core: #\(busiest.offset + 1) at \(pct(busiest.element))")
            }
            return HoverContent(
                title: "CPU — \(pct(cpu.total))",
                lines: lines,
                top: .init(label: "User", values: cpu.userHistory.values, color: .systemGreen, format: pct),
                bottom: .init(label: "System", values: cpu.systemHistory.values, color: .systemOrange, format: pct),
                timespan: "last 5 min")

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

    // MARK: - Menu (readouts, keep-awake, and the way into Settings)

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        hideHover()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
            self?.statusItem.button?.action = #selector(AppDelegate.statusButtonDown(_:))
        }
    }

    private func openMenu() {
        hideHover()
        statusItem.button?.action = nil   // the menu handles this click, not our drag tracker
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
    }

    func resetOrder() {
        setOrder(StatusGraphView.defaultOrder)
    }

    func setOrder(_ order: [StatusGraphView.Segment]) {
        Prefs.segmentOrder = order
        lastLayoutKey = ""
        refreshStatus()
        NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
    }

    /// "Connected now: LAN (en7), Wi‑Fi (en0)" for Settings ▸ Network.
    func networkSummary() -> String {
        let l = net.activeLinks
        if l.isEmpty { return "No active connections right now." }
        let list = l.map { "\($0.short) (\($0.id))" }.joined(separator: ", ")
        return l.count > 1 ? "Connected now: \(list). Separate graphs show when two or more are connected."
                           : "Connected now: \(list). A second connection gets its own graph."
    }

    func isSegmentShown(_ s: StatusGraphView.Segment) -> Bool {
        switch s {
        case .eyes: return Prefs.showEyes
        case .network: return Prefs.showNetwork
        case .battery: return Prefs.showBattery && BatteryMonitor.hasBattery
        case .disks: return diskSettings.showDisks
        case .cpu: return Prefs.showCPU
        }
    }

    /// Fallback path: if the local event monitor didn't see the mouse-down (it can miss status-bar
    /// clicks on some macOS versions), the button fires this on mouse-down instead.
    @objc private func statusButtonDown(_ sender: Any?) {
        guard !menuIsOpen, let e = NSApp.currentEvent else { return }
        if e.type == .rightMouseDown { openMenu(); return }
        if e.type == .leftMouseDown { graphView.trackMouse(from: e) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        #if !APPSTORE
        lidSleepDisabled = LidSleep.isDisabled
        #endif
        refreshStatus()
        menu.removeAllItems()

        menu.addItem(item("About BoostBar \(Updater.currentVersion)…", #selector(showAbout), on: false))
        let bits = Prefs.useBits
        let live = NSMenuItem(title: "▲ \(NetworkMonitor.format(net.currentUp, bits: bits, unit: Prefs.netUnit))    ▼ \(NetworkMonitor.format(net.currentDown, bits: bits, unit: Prefs.netUnit))", action: nil, keyEquivalent: "")
        live.isEnabled = false
        menu.addItem(live)
        if let b = battery {
            for line in BatteryMonitor.describe(b).split(separator: "\n") {
                let i = NSMenuItem(title: String(line), action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
        }

        // Keep awake stays one click away
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Keep Awake"))
        var awakeTitle = "Keep Mac Awake"
        if let until = sleep.until {
            awakeTitle += " (until \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)))"
        }
        menu.addItem(item(awakeTitle, #selector(toggleKeepAwake), on: sleep.isPreventing, key: "k"))
        let forItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for d in Self.awakeDurations.dropFirst() {
            let i = item(d.label, #selector(keepAwakeFor(_:)), on: false)
            i.representedObject = d.minutes
            sub.addItem(i)
        }
        forItem.submenu = sub
        menu.addItem(forItem)
        menu.addItem(item("Keep Display On Too", #selector(toggleDisplayAwakeMenu), on: sleep.keepDisplayAwake, indent: 1))
#if !APPSTORE
        menu.addItem(item("Stay Awake With Lid Closed", #selector(toggleLidSleep), on: lidSleepDisabled, key: "l"))
#endif

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), on: false, key: ","))
#if !APPSTORE
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates), on: false, key: "u"))
#endif
        menu.addItem(item("Buy Me an Energy Drink ⚡…", #selector(showAbout), on: false))
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

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        i.isEnabled = false
        return i
    }

    // MARK: - Actions (menu + Settings)

    @objc func openSettings() { settingsWindow.show() }

    @objc func toggleKeepAwake() {
        sleep.isPreventing ? sleep.allow() : sleep.prevent(for: nil)
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        keepAwake(minutes: sender.representedObject as? Int)
    }

    @objc private func toggleDisplayAwakeMenu() {
        setKeepDisplayAwake(!sleep.keepDisplayAwake)
        NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
    }

#if !APPSTORE
    @objc func toggleLidSleep() {
        let disable = !LidSleep.isDisabled
        if disable && !Prefs.bool(Prefs.K.lidWarningShown) {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Stay awake with the lid closed?"
            a.informativeText = """
            This runs “pmset -a disablesleep 1”: your Mac won’t sleep at all — including when the lid \
            is closed — until you turn it off here. It stays in effect after quitting or restarting.

            Don’t put a running Mac in a bag with this on; it can overheat and drain the battery.

            macOS will ask for your admin password (turn on “Toggle lid mode without a password” in Settings ▸ Sleep to skip that).
            """
            a.addButton(withTitle: "Disable Sleep")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else {
                NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
                return
            }
            Prefs.set(true, Prefs.K.lidWarningShown)
        }
        LidSleep.set(disabled: disable)
        lidSleepDisabled = LidSleep.isDisabled
        refreshStatus()
        NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
    }

    func toggleLidHelper() {
        let ok = LidSleep.helperInstalled ? LidSleep.removeHelper() : LidSleep.installHelper()
        if !ok {
            Updater.alert("Couldn't change the password-free rule", "The admin request was cancelled or failed.")
        }
        NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
    }

    func setReverseScroll(_ on: Bool) {
        Prefs.reverseScroll = on
        on ? scroll.start() : scroll.stop()
    }

    func setReverseTrackpad(_ on: Bool) {
        Prefs.reverseTrackpad = on
        scroll.reverseTrackpad = on
    }

    func setReverseHorizontal(_ on: Bool) {
        Prefs.reverseHorizontal = on
        scroll.reverseHorizontal = on
    }

    @objc func checkForUpdates() { updater.check(userInitiated: true) }

    func openGitHub() { NSWorkspace.shared.open(Updater.repoPage) }
#endif

    func toggleLaunchAtLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
            if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            Updater.alert("Couldn't change Launch at Login",
                          "\(error.localizedDescription)\n\nTip: move BoostBar.app into /Applications first.")
        }
        NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
    }

    @objc func showAbout() { SupportWindow.shared.show() }

    func toggleInstallPing() {
        InstallPing.isEnabled.toggle()
        if InstallPing.isEnabled { InstallPing.sendIfNeeded() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
