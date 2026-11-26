import Foundation
import IOKit

/// One sample of the internal battery, read from the AppleSmartBattery IORegistry entry.
struct BatteryReading {
    /// Positive = power flowing into the battery (charging), negative = out of it (discharging).
    var watts: Double
    var percent: Int?
    var externalConnected: Bool
    var isCharging: Bool
    var fullyCharged: Bool
    /// Minutes until empty while discharging, or until full while charging.
    var minutesRemaining: Int?
    /// Apple Silicon only: what the power adapter is delivering, and what the whole system is drawing.
    var adapterWatts: Double?
    var systemWatts: Double?
    /// Charge cycles so far, and full-charge capacity as a percent of the original design capacity.
    var cycleCount: Int?
    var healthPercent: Int?
    /// True for the short while after the charger is plugged in or pulled, when the battery's own current
    /// reading hasn't caught up yet and `watts` is worked out from the adapter and system power instead.
    var estimated = false

    enum Direction { case charging, discharging, idle }
    var direction: Direction {
        if watts > 0.05 { return .charging }
        if watts < -0.05 { return .discharging }
        return .idle
    }
}

enum BatteryMonitor {
    static let hasBattery: Bool = read() != nil

    // The battery's gas gauge only reports its current every half minute or so, but macOS knows at once whether the
    // charger is connected. Right after plugging in or unplugging, the stale current points the wrong way (still
    // "discharging" on the charger, still "charging" off it). Until the gauge reports again, that reading is
    // replaced by an estimate from what is known immediately.
    private static var lastExternal: Bool?
    private static var settling: (stamp: Int64, since: TimeInterval)?
    private static var lastSystemWatts: Double?

    static func read() -> BatteryReading? {
        guard var r = readRaw() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let s = r.reading.systemWatts { lastSystemWatts = s }
        if let was = lastExternal, was != r.reading.externalConnected { settling = (r.stamp, now) }
        lastExternal = r.reading.externalConnected
        if let s = settling {
            let ext = r.reading.externalConnected, w = r.reading.watts
            let contradicts = ext ? w < -0.05 : w > 0.05
            if r.stamp != s.stamp || now - s.since > 120 || (!contradicts && now - s.since > 3) {
                settling = nil                                   // the gauge has reported since the change
            } else {
                if ext {
                    // on the charger: what the adapter supplies beyond what the Mac uses goes into the battery
                    if let a = r.reading.adapterWatts, let sys = r.reading.systemWatts { r.reading.watts = max(0, a - sys) }
                    else { r.reading.watts = 0 }
                } else {
                    // off the charger: the battery carries the whole load
                    r.reading.watts = -(r.reading.systemWatts ?? lastSystemWatts ?? 0)
                }
                r.reading.isCharging = r.reading.watts > 0.05
                r.reading.minutesRemaining = nil
                r.reading.estimated = true
            }
        }
        return r.reading
    }

    private static func readRaw() -> (reading: BatteryReading, stamp: Int64)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        guard (dict["BatteryInstalled"] as? Bool) ?? true else { return nil }

        func num(_ key: String, in d: [String: Any] = dict) -> Int64? {
            (d[key] as? NSNumber).map { signed($0) }
        }
        func flag(_ key: String) -> Bool { (dict[key] as? Bool) ?? ((dict[key] as? NSNumber)?.boolValue ?? false) }

        guard let mV = num("Voltage"), let mA = num("InstantAmperage") ?? num("Amperage") else { return nil }
        let watts = Double(mV) * Double(mA) / 1_000_000

        // Capacity in mAh (raw keys on Apple Silicon; CurrentCapacity/MaxCapacity are mAh on Intel, % on Apple Silicon).
        let curMAh = num("AppleRawCurrentCapacity") ?? num("CurrentCapacity")
        let maxMAh = num("AppleRawMaxCapacity") ?? num("MaxCapacity")
        var percent: Int?
        if let c = num("CurrentCapacity"), let m = num("MaxCapacity"), m > 0 {
            percent = Int((Double(c) / Double(m) * 100).rounded())
        }

        let charging = flag("IsCharging") || watts > 0.05
        var minutes: Int?
        func valid(_ v: Int64?) -> Int? {
            guard let v, v > 0, v < 65_535 else { return nil }
            return Int(v)
        }
        let amps = abs(Double(mA))
        if charging {
            minutes = valid(num("AvgTimeToFull"))
            if minutes == nil, let c = curMAh, let m = maxMAh, amps > 50, m > c {
                minutes = Int(Double(m - c) / amps * 60)
            }
        } else if watts < -0.05 {
            minutes = valid(num("AvgTimeToEmpty")) ?? valid(num("TimeRemaining"))
            if minutes == nil, let c = curMAh, amps > 50 {
                minutes = Int(Double(c) / amps * 60)
            }
        }

        var health: Int?
        if let full = num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity"), let design = num("DesignCapacity"), design > 0 {
            health = Int((Double(full) / Double(design) * 100).rounded())
        }
        var adapter: Double?
        var system: Double?
        if let t = dict["PowerTelemetryData"] as? [String: Any] {
            if let v = num("SystemPowerIn", in: t), v > 0 { adapter = Double(v) / 1000 }
            if let v = num("SystemLoad", in: t), v > 0 { system = Double(v) / 1000 }
        }

        // changes whenever the gauge reports anew: its timestamp if there is one, else the current itself
        let stamp = num("UpdateTime") ?? mA
        return (BatteryReading(
            watts: watts,
            percent: percent,
            externalConnected: flag("ExternalConnected"),
            isCharging: charging,
            fullyCharged: flag("FullyCharged"),
            minutesRemaining: minutes,
            adapterWatts: adapter,
            systemWatts: system,
            cycleCount: num("CycleCount").map { Int($0) },
            healthPercent: health
        ), stamp)
    }

    /// IORegistry sometimes stores negative currents as unsigned 32- or 64-bit values.
    private static func signed(_ n: NSNumber) -> Int64 {
        let v = n.int64Value
        if v > Int64(Int32.max) && v <= Int64(UInt32.max) { return Int64(Int32(truncatingIfNeeded: v)) }
        return v
    }

    static func formatWatts(_ w: Double) -> String {
        let a = abs(w)
        return a < 10 ? String(format: "%.1fW", a) : String(format: "%.0fW", a)
    }

    static func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    /// Text for the hover tooltip and the menu.
    static func describe(_ r: BatteryReading) -> String {
        let pct = r.percent.map { " · \($0)%" } ?? ""
        var lines: [String] = []
        switch r.direction {
        case .discharging:
            lines.append("Battery discharging at \(formatWatts(r.watts))\(pct)")
            lines.append(r.minutesRemaining.map { "About \(formatDuration($0)) until empty" } ?? "Estimating time until empty…")
        case .charging:
            lines.append("Battery charging at \(formatWatts(r.watts))\(pct)")
            lines.append(r.minutesRemaining.map { "About \(formatDuration($0)) until full" } ?? "Estimating time until full…")
        case .idle:
            if r.externalConnected {
                lines.append(r.fullyCharged || (r.percent ?? 0) >= 100
                             ? "On power adapter · battery full\(pct)"
                             : "On power adapter · not charging\(pct)")
            } else {
                lines.append("Battery idle\(pct)")
            }
        }
        if r.estimated { lines.append("Just \(r.externalConnected ? "plugged in" : "unplugged") — estimated until the battery reports its current") }
        if r.externalConnected, let a = r.adapterWatts {
            var s = "Adapter supplying \(formatWatts(a))"
            if let sys = r.systemWatts { s += " · Mac using \(formatWatts(sys))" }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }
}
