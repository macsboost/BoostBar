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
        static let checkOnLaunch = "checkUpdatesOnLaunch"
        static let autoUpdate = "installUpdatesAutomatically"
        static let lidWarningShown = "lidWarningShown"
        static let showNetwork = "showNetwork"
        static let showBattery = "showBattery"
        static let upColor = "netUpColor"
        static let downColor = "netDownColor"
        static let showEyes = "showEyes"
        static let eyeSize = "eyeSize"
        static let singleEye = "singleEye"
        static let googly = "googlyEyes"
        static let eyeBlink = "eyeBlink"
        static let segmentOrder = "segmentOrder"
        static let crossEye = "allowCrossEye"
        static let bloodshot = "bloodshotEyes"
        static let pirate = "pirateEyes"
        static let cornerAwake = "hotCornerKeepAwake"
        static let cornerSleep = "hotCornerSleepNow"
    }

    static func registerDefaults() {
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
            K.eyeSize: 1,
            K.singleEye: false,
            K.googly: true,
            K.eyeBlink: true,
            K.crossEye: true,
            K.bloodshot: false,
            K.pirate: false,
        ])
    }

    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func set(_ v: Bool, _ k: String) { d.set(v, forKey: k) }

    static var useBits: Bool { get { bool(K.useBits) } set { set(newValue, K.useBits) } }
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
    /// 0 = small, 1 = medium, 2 = large
    static var eyeSize: Int { get { min(max(d.integer(forKey: K.eyeSize), 0), 2) } set { d.set(newValue, forKey: K.eyeSize) } }
    static var singleEye: Bool { get { bool(K.singleEye) } set { set(newValue, K.singleEye) } }
    static var googly: Bool { get { bool(K.googly) } set { set(newValue, K.googly) } }
    static var eyeBlink: Bool { get { bool(K.eyeBlink) } set { set(newValue, K.eyeBlink) } }
    /// Each eye aims at the pointer on its own, so they cross when it's between them.
    static var bloodshot: Bool { get { bool(K.bloodshot) } set { set(newValue, K.bloodshot) } }
    static var cornerAwake: Corner {
        get { Corner(rawValue: d.integer(forKey: K.cornerAwake)) ?? .none }
        set { d.set(newValue.rawValue, forKey: K.cornerAwake) }
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
            for s in StatusGraphView.defaultOrder where !out.contains(s) { out.append(s) }   // add any new pieces
            return out
        }
        set { d.set(newValue.map(\.rawValue), forKey: K.segmentOrder) }
    }
}

extension Notification.Name {
    /// Posted whenever app state changes outside the Settings window (menu toggles, timers, etc.).
    static let boostBarStateChanged = Notification.Name("BoostBarStateChanged")
}
