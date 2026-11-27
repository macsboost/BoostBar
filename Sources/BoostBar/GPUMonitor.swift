import Foundation
import IOKit

/// GPU load and memory, read from the graphics driver's own statistics in the I/O Registry
/// (IOAccelerator ▸ PerformanceStatistics). No permission needed; works on Apple silicon and Intel Macs.
final class GPUMonitor {
    /// Busy fraction 0…1 of the busiest GPU at the last sample.
    private(set) var utilization = 0.0
    /// Bytes of memory the GPU has in use, and what that is measured against: all of the Mac's memory on
    /// Apple silicon (the GPU shares it), the card's own VRAM on a discrete GPU. 0 when the driver doesn't say.
    private(set) var memoryUsed: Int64 = 0
    private(set) var memoryTotal: Int64 = 0
    private(set) var name = "GPU"
    /// True when memory is shared with the system (Apple silicon, integrated graphics).
    private(set) var unifiedMemory = true
    /// False until a driver has reported a utilization figure (a VM, or a very old GPU, may never).
    private(set) var available = false
    private(set) var history = History(capacity: 300)          // utilization, 5 min at 1 Hz
    private(set) var memoryHistory = History(capacity: 300)    // bytes in use

    var memoryFraction: Double { memoryTotal > 0 ? min(1, max(0, Double(memoryUsed) / Double(memoryTotal))) : 0 }

    init() { read() }

    /// Call once a second.
    func sample() {
        read()
        history.append(utilization)
        memoryHistory.append(Double(memoryUsed))
    }

    private func read() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var best: (util: Double, used: Int64, total: Int64, name: String?, unified: Bool)?
        while true {
            let service = IOIteratorNext(it)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            func num(_ keys: String...) -> Double? {
                for k in keys { if let n = stats[k] as? NSNumber { return n.doubleValue } }
                return nil
            }
            guard let pct = num("Device Utilization %", "GPU Activity(%)") else { continue }
            let util = min(1, max(0, pct / 100))
            var used: Int64 = 0, total: Int64 = 0, unified = true
            if let u = num("VRAM Used Bytes", "vramUsedBytes"), let f = num("VRAM Free Bytes", "vramFreeBytes"), u + f > 0 {
                used = Int64(u); total = Int64(u + f); unified = false          // a card with its own memory
            } else if let u = num("In use system memory") {
                used = Int64(u); total = Int64(ProcessInfo.processInfo.physicalMemory)
            }
            if best == nil || util > best!.util {
                best = (util, used, total, Self.model(of: service), unified)
            }
        }
        guard let b = best else { return }
        available = true
        utilization = b.util; memoryUsed = b.used; memoryTotal = b.total; unifiedMemory = b.unified
        if let n = b.name { name = n }
    }

    /// "Apple M2 Pro", "AMD Radeon Pro 5500M", … from the driver or the device above it.
    private static func model(of service: io_service_t) -> String? {
        let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let v = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "model" as CFString, kCFAllocatorDefault, opts) else { return nil }
        var s: String?
        if let str = v as? String { s = str }
        else if let data = v as? Data { s = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
        s = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        // the search climbs to the top of the registry, where "model" is the Mac itself ("MacBookPro18,3"): not a GPU name
        if let n = s, n.isEmpty || n.contains(",") { return nil }
        return s
    }
}
