import AppKit

/// All user settings in one place (UserDefaults-backed).
enum Prefs {
    private static let d = UserDefaults.standard

    enum K {
        static let reverseScroll = "reverseScroll"
        static let reverseTrackpad = "reverseTrackpad"
        static let reverseHorizontal = "reverseHorizontal"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let useBits = "useBits"
        static let netUnit = "networkUnit"
        static let checkOnLaunch = "checkUpdatesOnLaunch"
        static let autoUpdate = "installUpdatesAutomatically"
        static let lidWarningShown = "lidWarningShown"
        static let showNetwork = "showNetwork"
        static let showBattery = "showBattery"
        static let upColor = "netUpColor"
        static let downColor = "netDownColor"
        static let showEyes = "showEyes"
        static let showCPU = "showCPU"
        static let cpuStyle = "cpuStyle"
        static let cpuRate = "cpuUpdatesPerSecond"
        static let cpuBackdrop = "cpuBackdrop"
        static let cpuPeakHold = "cpuPeakHoldSeconds"
        static let eyeSize = "eyeSize"
        static let singleEye = "singleEye"
        static let googly = "googlyEyes"
        static let lazyEyes = "lazyEyes"
        static let eyeBlink = "eyeBlink"
        static let segmentOrder = "segmentOrder"
        static let crossEye = "allowCrossEye"
        static let bloodshot = "bloodshotEyes"
        static let bloodshotAwake = "bloodshotWhenAwake"
        static let shakeEyes = "dizzyEyesOnShake"
        static let netSplit = "networkGraphPerConnection"
        static let verticalLabels = "verticalLabels"
        static let pirate = "pirateEyes"
        static let cornerAwake = "hotCornerKeepAwake"
        static let cornerSleep = "hotCornerSleepNow"
        static let cornerSaver = "hotCornerScreenSaver"
    }

    static func registerDefaults() {
        // Fresh install (BoostBar has never run here): start with the googly eyes on and large,
        // and medium disk LEDs. Existing users keep whatever they had.
        if d.object(forKey: "supportShownOnce") == nil && d.object(forKey: K.showEyes) == nil {
            d.set(true, forKey: K.showEyes)
            d.set(2, forKey: K.eyeSize)
            if d.object(forKey: "ledSize") == nil { d.set(1, forKey: "ledSize") }
        }
        d.register(defaults: [
            K.reverseScroll: false,
            K.reverseTrackpad: false,
            K.reverseHorizontal: false,
            K.keepDisplayAwake: false,
            K.useBits: false,
            K.checkOnLaunch: true,
            K.showNetwork: true,
            K.showBattery: BatteryMonitor.hasBattery,
            K.upColor: "White",
            K.downColor: "White",
            K.showEyes: false,
            K.showCPU: true,
            K.cpuStyle: 0,
            K.cpuRate: 5.0,
            K.eyeSize: 1,
            K.singleEye: false,
            K.googly: true,
            K.eyeBlink: true,
            K.crossEye: true,
            K.bloodshot: false,
            K.bloodshotAwake: true,
            K.shakeEyes: true,
            K.netSplit: true,
            K.pirate: false,
        ])
    }

    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func set(_ v: Bool, _ k: String) { d.set(v, forKey: k) }

    static var useBits: Bool { get { bool(K.useBits) } set { set(newValue, K.useBits) } }
    static var netUnit: NetworkMonitor.Unit {
        get { NetworkMonitor.Unit(rawValue: d.integer(forKey: K.netUnit)) ?? .auto }
        set { d.set(newValue.rawValue, forKey: K.netUnit) }
    }
    static var showNetwork: Bool { get { bool(K.showNetwork) } set { set(newValue, K.showNetwork) } }
    static var showBattery: Bool { get { bool(K.showBattery) } set { set(newValue, K.showBattery) } }
    static var checkOnLaunch: Bool { get { bool(K.checkOnLaunch) } set { set(newValue, K.checkOnLaunch) } }
    static var autoUpdate: Bool { get { bool(K.autoUpdate) } set { set(newValue, K.autoUpdate) } }
    static var keepDisplayAwake: Bool { get { bool(K.keepDisplayAwake) } set { set(newValue, K.keepDisplayAwake) } }
    static var reverseScroll: Bool { get { bool(K.reverseScroll) } set { set(newValue, K.reverseScroll) } }
    static var reverseTrackpad: Bool { get { bool(K.reverseTrackpad) } set { set(newValue, K.reverseTrackpad) } }
    static var reverseHorizontal: Bool { get { bool(K.reverseHorizontal) } set { set(newValue, K.reverseHorizontal) } }

    /// Store a palette name (e.g. "Boost Green") rather than a hex value.
    static func setTraceColors(up: String, down: String) {
        d.set(up, forKey: K.upColor)
        d.set(down, forKey: K.downColor)
    }

    static var upColor: NSColor {
        get { Palette.resolve(d.string(forKey: K.upColor), default: .white) }
        set { d.set(newValue.hexString, forKey: K.upColor) }
    }
    static var downColor: NSColor {
        get { Palette.resolve(d.string(forKey: K.downColor), default: .white) }
        set { d.set(newValue.hexString, forKey: K.downColor) }
    }

    // Googly eyes
    static var showEyes: Bool { get { bool(K.showEyes) } set { set(newValue, K.showEyes) } }
    static var showCPU: Bool { get { bool(K.showCPU) } set { set(newValue, K.showCPU) } }
    /// 0 = half-round boost gauge, 1 = a vertical bar per core
    /// CPU readings per second, 1…60.
    static var cpuRate: Double {
        get { min(60, max(1, d.double(forKey: K.cpuRate))) }
        set { d.set(min(60, max(1, newValue)), forKey: K.cpuRate) }
    }
    /// Backdrop behind the CPU meter: -1 (strong dark) … 0 (none) … +1 (strong light).
    static var cpuBackdrop: Double {
        get { min(1, max(-1, d.double(forKey: K.cpuBackdrop))) }
        set { d.set(abs(newValue) < 0.04 ? 0 : min(1, max(-1, newValue)), forKey: K.cpuBackdrop) }
    }
    /// Spectrum analyzer: seconds each core's peak marker stays up before it falls; 0 = no peak markers.
    static var cpuPeakHold: Double {
        get { min(10, max(0, d.double(forKey: K.cpuPeakHold))) }
        set { d.set(newValue < 0.2 ? 0 : min(10, newValue), forKey: K.cpuPeakHold) }
    }
    static var cpuStyle: Int { get { d.integer(forKey: K.cpuStyle) } set { d.set(newValue, forKey: K.cpuStyle) } }
    /// 0 = small, 1 = medium, 2 = large
    static var eyeSize: Int { get { min(max(d.integer(forKey: K.eyeSize), 0), 2) } set { d.set(newValue, forKey: K.eyeSize) } }
    static var singleEye: Bool { get { bool(K.singleEye) } set { set(newValue, K.singleEye) } }
    static var googly: Bool { get { bool(K.googly) } set { set(newValue, K.googly) } }
    static var lazyEyes: Bool { get { bool(K.lazyEyes) } set { set(newValue, K.lazyEyes) } }
    static var eyeBlink: Bool { get { bool(K.eyeBlink) } set { set(newValue, K.eyeBlink) } }
    /// Each eye aims at the pointer on its own, so they cross when it's between them.
    static var bloodshot: Bool { get { bool(K.bloodshot) } set { set(newValue, K.bloodshot) } }
    static var verticalLabels: Bool { get { bool(K.verticalLabels) } set { set(newValue, K.verticalLabels) } }
    static var netSplit: Bool { get { bool(K.netSplit) } set { set(newValue, K.netSplit) } }
    static var shakeEyes: Bool { get { bool(K.shakeEyes) } set { set(newValue, K.shakeEyes) } }
    static var bloodshotAwake: Bool { get { bool(K.bloodshotAwake) } set { set(newValue, K.bloodshotAwake) } }
    static var cornerAwake: Corner {
        get { Corner(rawValue: d.integer(forKey: K.cornerAwake)) ?? .none }
        set { d.set(newValue.rawValue, forKey: K.cornerAwake) }
    }
    static var cornerSaver: Corner {
        get { Corner(rawValue: d.integer(forKey: K.cornerSaver)) ?? .none }
        set { d.set(newValue.rawValue, forKey: K.cornerSaver) }
    }
    static var cornerSleep: Corner {
        get { Corner(rawValue: d.integer(forKey: K.cornerSleep)) ?? .none }
        set { d.set(newValue.rawValue, forKey: K.cornerSleep) }
    }
    static var pirate: Bool { get { bool(K.pirate) } set { set(newValue, K.pirate) } }
    static var allowCrossEye: Bool { get { bool(K.crossEye) } set { set(newValue, K.crossEye) } }

    static let sizeNames = ["Small", "Medium", "Large"]

    /// Left-to-right order of the menu bar pieces (eyes, network, battery, disks).
    static var segmentOrder: [StatusGraphView.Segment] {
        get {
            let saved = (d.stringArray(forKey: K.segmentOrder) ?? []).compactMap(StatusGraphView.Segment.init(rawValue:))
            var out: [StatusGraphView.Segment] = []
            for s in saved where !out.contains(s) { out.append(s) }
            // add any new pieces where the default order has them (the CPU gauge goes just before the disk lights)
            for s in StatusGraphView.defaultOrder where !out.contains(s) {
                if let i = StatusGraphView.defaultOrder.firstIndex(of: s), i + 1 < StatusGraphView.defaultOrder.count,
                   let at = out.firstIndex(of: StatusGraphView.defaultOrder[i + 1]) { out.insert(s, at: at) } else { out.append(s) }
            }
            return out
        }
        set { d.set(newValue.map(\.rawValue), forKey: K.segmentOrder) }
    }
}

extension Notification.Name {
    /// Posted whenever app state changes outside the Settings window (menu toggles, timers, etc.).
    static let boostBarStateChanged = Notification.Name("BoostBarStateChanged")
}
