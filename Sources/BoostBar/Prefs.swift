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
        ])
    }

    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func set(_ v: Bool, _ k: String) { d.set(v, forKey: k) }

    static var useBits: Bool { get { bool(K.useBits) } set { set(newValue, K.useBits) } }
    static var showNetwork: Bool { get { bool(K.showNetwork) } set { set(newValue, K.showNetwork) } }
    static var showBattery: Bool { get { bool(K.showBattery) } set { set(newValue, K.showBattery) } }
    static var checkOnLaunch: Bool { get { bool(K.checkOnLaunch) } set { set(newValue, K.checkOnLaunch) } }
    static var keepDisplayAwake: Bool { get { bool(K.keepDisplayAwake) } set { set(newValue, K.keepDisplayAwake) } }
    static var reverseScroll: Bool { get { bool(K.reverseScroll) } set { set(newValue, K.reverseScroll) } }
    static var reverseTrackpad: Bool { get { bool(K.reverseTrackpad) } set { set(newValue, K.reverseTrackpad) } }
    static var reverseHorizontal: Bool { get { bool(K.reverseHorizontal) } set { set(newValue, K.reverseHorizontal) } }

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

    static let sizeNames = ["Small", "Medium", "Large"]
}

extension Notification.Name {
    /// Posted whenever app state changes outside the Settings window (menu toggles, timers, etc.).
    static let boostBarStateChanged = Notification.Name("BoostBarStateChanged")
}
