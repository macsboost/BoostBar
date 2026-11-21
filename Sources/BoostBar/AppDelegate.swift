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

    private enum Key {
        static let reverseScroll = "reverseScroll"
        static let reverseTrackpad = "reverseTrackpad"
        static let reverseHorizontal = "reverseHorizontal"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let useBits = "useBits"
        static let checkOnLaunch = "checkUpdatesOnLaunch"
        static let lidWarningShown = "lidWarningShown"
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
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: StatusGraphView.totalWidth)
        if let button = statusItem.button {
            graphView.frame = button.bounds
            graphView.autoresizingMask = [.width, .height]
            button.addSubview(graphView)
            button.setAccessibilityLabel("BoostBar")
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        scroll.reverseTrackpad = defaults.bool(forKey: Key.reverseTrackpad)
        scroll.reverseHorizontal = defaults.bool(forKey: Key.reverseHorizontal)
        if defaults.bool(forKey: Key.reverseScroll) { scroll.start() }

        sleep.keepDisplayAwake = defaults.bool(forKey: Key.keepDisplayAwake)
        sleep.onChange = { [weak self] in self?.refreshStatus() }

        lidSleepDisabled = LidSleep.isDisabled

        net.onUpdate = { [weak self] in self?.refreshStatus() }
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

    private func refreshStatus() {
        let bits = defaults.bool(forKey: Key.useBits)
        graphView.up = net.upHistory
        graphView.down = net.downHistory
        graphView.upText = NetworkMonitor.format(net.currentUp, bits: bits)
        graphView.downText = NetworkMonitor.format(net.currentDown, bits: bits)
        graphView.awake = lidSleepDisabled ? .lidAwake : (sleep.isPreventing ? .keepAwake : .normal)
        graphView.needsDisplay = true

        var tip = "Upload \(graphView.upText) · Download \(graphView.downText)"
        if lidSleepDisabled { tip += "\nSleep disabled (incl. lid closed)" }
        else if sleep.isPreventing { tip += "\nKeeping awake" }
        statusItem.button?.toolTip = tip
    }

    // MARK: - Menu

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
        ScrollReverser.promptForPermission()
        ScrollReverser.openAccessibilitySettings()
    }

    // MARK: - Actions: misc

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
