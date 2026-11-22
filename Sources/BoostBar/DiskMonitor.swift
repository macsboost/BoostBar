import Foundation
import IOKit

/// Watches every physical drive (internal SSD, USB flash drives, external disks, SD cards)
/// through IOBlockStorageDriver statistics — no special permission needed.
///  • Fast poll (every ~½ LED duration) to blink an LED on each read/write.
///  • 1 Hz sampling of bytes read/written for the hover charts.
final class DiskMonitor {
    struct Drive: Equatable {
        let key: String           // stable identity for settings (serial/name/size)
        let bsd: String           // e.g. disk0, disk4
        let name: String          // IOMedia name, e.g. "APPLE SSD AP1024Z Media"
        let interconnect: String  // "Apple Fabric", "PCI-Express", "USB", "SD"…
        let isInternal: Bool
        let isRemovable: Bool
        let size: Int64
        fileprivate let driver: io_registry_entry_t

        static func == (a: Drive, b: Drive) -> Bool { a.key == b.key && a.bsd == b.bsd }

        var displayName: String { "\(name) (\(bsd))" }
        var kind: String {
            var k = isInternal ? "Internal" : "External"
            if !interconnect.isEmpty { k += " · \(interconnect)" }
            if isRemovable { k += " · Removable" }
            return k
        }
    }

    struct Volume {
        let name: String
        let mountPoint: String
        let available: Int64
        let total: Int64
    }

    private(set) var drives: [Drive] = []
    private(set) var lit: Set<String> = []                 // keys of drives whose LED is on
    private(set) var readHistory: [String: History] = [:]  // bytes/sec, 60 s
    private(set) var writeHistory: [String: History] = [:]

    /// Which drives get an LED; set by the app from user settings.
    var enabledKeys: Set<String> = [] { didSet { reschedule() } }
    var ledDurationMs: Double = 35 { didSet { reschedule() } }
    var isActive = true { didSet { reschedule() } }

    var onLEDChange: (() -> Void)?
    var onDrivesChanged: (() -> Void)?

    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var lastOps: [String: UInt64] = [:]
    private var lastActivity: [String: TimeInterval] = [:]
    private var lastBytes: [String: (r: UInt64, w: UInt64, t: TimeInterval)] = [:]
    private var enumerateCountdown = 0

    func start() {
        refreshDrives()
        let slow = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.secondTick() }
        slow.tolerance = 0.1
        RunLoop.main.add(slow, forMode: .common)
        slowTimer = slow
        reschedule()
    }

    deinit {
        for d in drives { IOObjectRelease(d.driver) }
    }

    // MARK: Polling

    private func reschedule() {
        fastTimer?.invalidate()
        fastTimer = nil
        let anyOn = isActive && drives.contains(where: { enabledKeys.contains($0.key) })
        if !anyOn {
            if !lit.isEmpty { lit.removeAll(); onLEDChange?() }
            return
        }
        // Sample at half the LED duration (bounded) so short blinks aren't missed.
        let interval = min(max(ledDurationMs / 2000, 0.015), 0.1)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.fastTick() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    private func fastTick() {
        let now = ProcessInfo.processInfo.systemUptime
        var newLit = Set<String>()
        for d in drives where enabledKeys.contains(d.key) {
            guard let s = Self.stats(d.driver) else { continue }
            let ops = s.readOps &+ s.writeOps
            if let prev = lastOps[d.key], ops != prev { lastActivity[d.key] = now }
            lastOps[d.key] = ops
            if let a = lastActivity[d.key], (now - a) * 1000 < ledDurationMs { newLit.insert(d.key) }
        }
        if newLit != lit {
            lit = newLit
            onLEDChange?()
        }
    }

    private func secondTick() {
        enumerateCountdown -= 1
        if enumerateCountdown <= 0 {
            enumerateCountdown = 3          // look for plugged/unplugged drives every 3 s
            refreshDrives()
        }
        let now = ProcessInfo.processInfo.systemUptime
        for d in drives {
            guard let s = Self.stats(d.driver) else { continue }
            var r = readHistory[d.key] ?? History(capacity: 60)
            var w = writeHistory[d.key] ?? History(capacity: 60)
            if let prev = lastBytes[d.key] {
                let dt = max(now - prev.t, 0.001)
                r.append(s.readBytes >= prev.r ? Double(s.readBytes - prev.r) / dt : 0)
                w.append(s.writeBytes >= prev.w ? Double(s.writeBytes - prev.w) / dt : 0)
            }
            lastBytes[d.key] = (s.readBytes, s.writeBytes, now)
            readHistory[d.key] = r
            writeHistory[d.key] = w
        }
    }

    private func refreshDrives() {
        let found = Self.enumerate()
        if found.map(\.key) == drives.map(\.key) && found.map(\.bsd) == drives.map(\.bsd) {
            for d in found { IOObjectRelease(d.driver) }
            return
        }
        for d in drives { IOObjectRelease(d.driver) }
        drives = found
        let keys = Set(found.map(\.key))
        lastOps = lastOps.filter { keys.contains($0.key) }
        lastBytes = lastBytes.filter { keys.contains($0.key) }
        lit = lit.filter { keys.contains($0) }
        onDrivesChanged?()
        reschedule()
    }

    // MARK: IOKit

    private struct Stats { let readOps, writeOps, readBytes, writeBytes: UInt64 }

    private static func stats(_ driver: io_registry_entry_t) -> Stats? {
        guard let cf = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
              let s = cf as? [String: Any] else { return nil }
        func n(_ k: String) -> UInt64 { (s[k] as? NSNumber)?.uint64Value ?? 0 }
        return Stats(readOps: n("Operations (Read)"), writeOps: n("Operations (Write)"),
                     readBytes: n("Bytes (Read)"), writeBytes: n("Bytes (Write)"))
    }

    private static func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func searchUp(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(e, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively))
    }

    private static func enumerate() -> [Drive] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }

        var result: [Drive] = []
        var driver = IOIteratorNext(iter)
        while driver != 0 {
            defer { driver = IOIteratorNext(iter) }
            var media: io_registry_entry_t = 0
            guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &media) == KERN_SUCCESS else {
                IOObjectRelease(driver); continue
            }
            defer { IOObjectRelease(media) }

            guard let bsd = prop(media, "BSD Name") as? String,
                  let size = (prop(media, "Size") as? NSNumber)?.int64Value, size > 0 else {
                IOObjectRelease(driver); continue
            }
            let proto = searchUp(driver, "Protocol Characteristics") as? [String: Any] ?? [:]
            let interconnect = proto["Physical Interconnect"] as? String ?? ""
            let location = proto["Physical Interconnect Location"] as? String ?? ""
            if interconnect.localizedCaseInsensitiveContains("virtual") || location == "File" {
                IOObjectRelease(driver); continue        // skip mounted disk images
            }

            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(media, &nameBuf)
            let name = String(cString: nameBuf)
            let chars = searchUp(driver, "Device Characteristics") as? [String: Any] ?? [:]
            let serial = (chars["Serial Number"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let removable = (prop(media, "Removable") as? Bool) ?? false
            let ejectable = (prop(media, "Ejectable") as? Bool) ?? false

            result.append(Drive(
                key: serial.isEmpty ? "\(name)|\(size)" : "\(serial)|\(name)",
                bsd: bsd,
                name: name,
                interconnect: interconnect,
                isInternal: location == "Internal",
                isRemovable: removable || ejectable,
                size: size,
                driver: driver    // retained; released when the drive list changes
            ))
        }
        return result.sorted { ($0.bsd.count, $0.bsd) < ($1.bsd.count, $1.bsd) }
    }

    /// Mounted, user-visible volumes that live on this physical drive (APFS volumes are traced
    /// back through their container to the physical disk).
    func volumes(on drive: Drive) -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [Volume] = []
        for url in urls {
            var st = statfs()
            guard statfs(url.path, &st) == 0 else { continue }
            let from = withUnsafePointer(to: &st.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard from.hasPrefix("/dev/") else { continue }
            let bsd = String(from.dropFirst(5))
            guard Self.physicalDriver(forBSD: bsd, matches: drive.driver) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let avail = v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
            out.append(Volume(name: v?.volumeName ?? url.lastPathComponent, mountPoint: url.path,
                              available: avail, total: Int64(v?.volumeTotalCapacity ?? 0)))
        }
        return out
    }

    private static func physicalDriver(forBSD bsd: String, matches target: io_registry_entry_t) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard service != 0 else { return false }
        var entry: io_registry_entry_t = service
        for _ in 0..<32 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                let same = IOObjectIsEqualTo(entry, target) != 0
                IOObjectRelease(entry)
                return same
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { return false }
            entry = parent
        }
        IOObjectRelease(entry)
        return false
    }

    static func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
