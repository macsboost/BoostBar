import AppKit

/// Holds closures for AppKit target/action.
private final class ActionBox: NSObject {
    let fire: (Any?) -> Void
    init(_ fire: @escaping (Any?) -> Void) { self.fire = fire }
    @objc func run(_ sender: Any?) { fire(sender) }
}

/// One settings tab: a vertical list of controls, each with a refresher that re-reads its state.
private final class Pane: NSViewController {
    private let stack = NSStackView()
    private var refreshers: [() -> Void] = []
    private var boxes: [ActionBox] = []
    private let build: (Pane) -> Void

    init(title: String, symbol: String, build: @escaping (Pane) -> Void) {
        self.build = build
        super.init(nibName: nil, bundle: nil)
        self.title = title
        _ = symbol
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 470))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor),
        ])
        view = v
        preferredContentSize = v.frame.size
        build(self)
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() { refreshers.forEach { $0() } }

    private func box(_ f: @escaping (Any?) -> Void) -> ActionBox {
        let b = ActionBox(f); boxes.append(b); return b
    }

    // MARK: Builders

    func header(_ text: String) {
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        if !stack.arrangedSubviews.isEmpty { stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!) }
        stack.addArrangedSubview(t)
    }

    func note(_ text: String, indent: Bool = false) {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 540
        add(t, indent: indent)
    }

    @discardableResult
    func check(_ title: String, indent: Bool = false,
               get: @escaping () -> Bool, set: @escaping (Bool) -> Void,
               enabled: (() -> Bool)? = nil) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        let bx = box { [weak b] _ in if let b { set(b.state == .on) } }
        b.target = bx; b.action = #selector(ActionBox.run(_:))
        refreshers.append { [weak b] in
            b?.state = get() ? .on : .off
            if let enabled { b?.isEnabled = enabled() }
        }
        add(b, indent: indent)
        return b
    }

    func popup(_ label: String, items: [String], indent: Bool = false,
               get: @escaping () -> Int, set: @escaping (Int) -> Void,
               trailing: NSView? = nil, enabled: (() -> Bool)? = nil) {
        let l = NSTextField(labelWithString: label)
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

    func color(_ label: String, get: @escaping () -> NSColor, set: @escaping (NSColor) -> Void) {
        let l = NSTextField(labelWithString: label)
        l.widthAnchor.constraint(equalToConstant: 120).isActive = true
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

    func makeButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let bx = box { _ in action() }
        let b = NSButton(title: title, target: bx, action: #selector(ActionBox.run(_:)))
        b.bezelStyle = .rounded
        return b
    }

    func label(indent: Bool = false, get: @escaping () -> String) {
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        refreshers.append { [weak t] in t?.stringValue = get() }
        add(t, indent: indent)
    }

    func custom(_ v: NSView, height: CGFloat, onRefresh: (() -> Void)? = nil) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        if let onRefresh { refreshers.append(onRefresh) }
    }

    func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    private func add(_ v: NSView, indent: Bool) {
        if indent {
            let r = NSStackView(views: [v])
            r.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            stack.addArrangedSubview(r)
        } else {
            stack.addArrangedSubview(v)
        }
    }
}

/// BoostBar ▸ Settings… — every option, grouped in tabs.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private unowned let app: AppDelegate
    private var window: NSWindow?
    private var tabs: NSTabViewController?
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
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard window?.isVisible == true else { return }
        drivesTable?.reload()
        panes.forEach { if $0.isViewLoaded { $0.refresh() } }
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        self.tabs = tabs

        panes = makePanes()
        let symbols: [String: String] = [
            "General": "gearshape", "Sleep": "moon.zzz", "Network": "network", "Battery": "battery.75percent",
            "Disks": "internaldrive", "Eyes": "eyes", "Scrolling": "computermouse",
        ]
        for p in panes {
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
        w.setContentSize(NSSize(width: 620, height: 470))
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
            let gh = p.makeButton("BoostBar on GitHub") { app.openGitHub() }
            let row = p.row([p.makeButton("Check Now") { app.checkForUpdates() }, gh])
            p.custom(row, height: 28)
            #endif
            p.header("Menu Bar Layout")
            p.note("Drag any piece of BoostBar in the menu bar (eyes, network graph, battery watts, disk lights) left or right to change the order. A plain click opens the menu.")
            p.button("Reset Order") { app.resetOrder() }
            p.header("Privacy")
            p.check("Share anonymous install count", get: { InstallPing.isEnabled }, set: { _ in app.toggleInstallPing() })
            p.note("Sends biz-cord.com a random ID, the BoostBar version, macOS version and CPU type, once per version. No personal info.", indent: true)
            p.header("About")
            let about = p.row([p.makeButton("About BoostBar…") { app.showAbout() },
                               p.makeButton("Buy Me an Energy Drink ⚡") { app.showAbout() }])
            p.custom(about, height: 28)
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
            #if !APPSTORE
            p.header("Lid Closed")
            p.check("Stay awake with the lid closed", get: { app.lidSleepDisabled }, set: { _ in app.toggleLidSleep() })
            p.note("Runs “pmset -a disablesleep 1” (admin password). Stays on after quitting or restarting until you turn it off. Don’t bag a running Mac with this on.", indent: true)
            p.check("Toggle lid mode without a password", indent: true, get: { LidSleep.helperInstalled }, set: { _ in app.toggleLidHelper() })
            #endif
            p.note("Keep Awake is also in the BoostBar menu for one-click access.")
        })

        // Network
        list.append(Pane(title: "Network", symbol: "network") { p in
            p.header("Menu Bar")
            p.check("Show network speed graph", get: { Prefs.showNetwork }, set: { Prefs.showNetwork = $0; app.applySettings() })
            p.check("Show bits per second (Kb/s) instead of bytes (KB/s)", get: { Prefs.useBits }, set: { Prefs.useBits = $0; app.applySettings() })
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
            p.custom(p.row([NSTextField(labelWithString: "Presets:")] + presets), height: 28)
            p.note("Hover over the graph in the menu bar for a 5-minute chart.")
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
            p.check("Googly wobble", get: { Prefs.googly }, set: { Prefs.googly = $0; app.applySettings() })
            p.check("Blink now and then", get: { Prefs.eyeBlink }, set: { Prefs.eyeBlink = $0; app.applySettings() })
            p.check("Bloodshot 🩸", get: { Prefs.bloodshot }, set: { Prefs.bloodshot = $0; app.applySettings() })
            p.check("Allow cross-eyed (each eye follows the pointer on its own)", get: { Prefs.allowCrossEye },
                    set: { Prefs.allowCrossEye = $0; app.applySettings() },
                    enabled: { !Prefs.singleEye })
            p.note("A tribute to the classic desktop toys that kept an eye on your cursor.")
        })

        #if !APPSTORE
        // Scrolling
        list.append(Pane(title: "Scrolling", symbol: "computermouse") { p in
            p.header("Mouse Scrolling")
            p.check("Reverse mouse scrolling", get: { Prefs.reverseScroll }, set: { app.setReverseScroll($0) })
            p.check("Include trackpad / Magic Mouse", indent: true, get: { Prefs.reverseTrackpad }, set: { app.setReverseTrackpad($0) })
            p.check("Include horizontal scrolling", indent: true, get: { Prefs.reverseHorizontal }, set: { app.setReverseHorizontal($0) })
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
