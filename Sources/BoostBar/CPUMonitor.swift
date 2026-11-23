import Foundation

/// Whole-machine CPU load, sampled from the kernel's per-core tick counters (no permission needed).
final class CPUMonitor {
    /// Busy fraction 0…1 of each core over the last sample interval, and of all cores together.
    private(set) var cores: [Double] = []
    private(set) var total: Double = 0
    /// user / system share of the total (0…1 each).
    private(set) var user: Double = 0
    private(set) var system: Double = 0
    private(set) var history = History(capacity: 300)    // total, 5 min at 1 Hz
    private(set) var userHistory = History(capacity: 300)
    private(set) var systemHistory = History(capacity: 300)
    private var last: [[UInt32]] = []

    private func ticks() -> [[UInt32]]? {
        var count = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let n = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { c in (0..<n).map { UInt32(bitPattern: info[c * n + $0]) } }
    }

    private var sinceRecord = 0.0, accTotal = 0.0, accUser = 0.0, accSystem = 0.0, accN = 0.0
    private var lastTime = ProcessInfo.processInfo.systemUptime

    /// Call a few times a second; the 5-minute history still gets one (averaged) point per second.
    func sample() {
        guard let cur = ticks() else { return }
        defer { last = cur }
        guard last.count == cur.count else { return }
        var busyAll = 0.0, allAll = 0.0, userAll = 0.0, sysAll = 0.0
        cores = zip(cur, last).map { a, b in
            let u = Double(a[Int(CPU_STATE_USER)] &- b[Int(CPU_STATE_USER)]) + Double(a[Int(CPU_STATE_NICE)] &- b[Int(CPU_STATE_NICE)])
            let s = Double(a[Int(CPU_STATE_SYSTEM)] &- b[Int(CPU_STATE_SYSTEM)])
            let i = Double(a[Int(CPU_STATE_IDLE)] &- b[Int(CPU_STATE_IDLE)])
            busyAll += u + s; allAll += u + s + i; userAll += u; sysAll += s
            return u + s + i > 0 ? (u + s) / (u + s + i) : 0
        }
        total = allAll > 0 ? busyAll / allAll : 0
        user = allAll > 0 ? userAll / allAll : 0
        system = allAll > 0 ? sysAll / allAll : 0
        let now = ProcessInfo.processInfo.systemUptime
        sinceRecord += now - lastTime; lastTime = now
        accTotal += total; accUser += user; accSystem += system; accN += 1
        if sinceRecord >= 1 {
            history.append(accTotal / accN); userHistory.append(accUser / accN); systemHistory.append(accSystem / accN)
            sinceRecord = 0; accTotal = 0; accUser = 0; accSystem = 0; accN = 0
        }
    }
}
