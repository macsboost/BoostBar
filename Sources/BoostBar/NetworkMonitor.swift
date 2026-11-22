import Foundation
import Darwin

/// Samples total bytes in/out across physical interfaces once per second.
/// Uses sysctl NET_RT_IFLIST2, which exposes 64-bit counters (getifaddrs wraps at 4 GB).
final class NetworkMonitor {
    let capacity: Int
    private(set) var upHistory: [Double]     // bytes per second, oldest first
    private(set) var downHistory: [Double]
    /// Longer history (5 minutes at 1 Hz) for the hover chart.
    private(set) var longUp = History(capacity: 300)
    private(set) var longDown = History(capacity: 300)
    var onUpdate: (() -> Void)?

    private var last: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    private var timer: Timer?

    /// Virtual / tunnel interfaces that would double-count traffic.
    private static let ignoredPrefixes = ["lo", "utun", "ipsec", "gif", "stf", "awdl", "llw", "bridge", "anpi", "ppp"]

    init(capacity: Int = 30) {
        self.capacity = capacity
        upHistory = Array(repeating: 0, count: capacity)
        downHistory = Array(repeating: 0, count: capacity)
    }

    var currentUp: Double { upHistory.last ?? 0 }
    var currentDown: Double { downHistory.last ?? 0 }

    func start(interval: TimeInterval = 1.0) {
        sample()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)   // keep ticking while the menu is open
        timer = t
    }

    private func sample() {
        let c = Self.readCounters()
        let now = ProcessInfo.processInfo.systemUptime
        if let l = last {
            let dt = max(now - l.t, 0.001)
            let up = c.tx >= l.tx ? Double(c.tx - l.tx) / dt : 0
            let down = c.rx >= l.rx ? Double(c.rx - l.rx) / dt : 0
            upHistory.append(up); upHistory.removeFirst(upHistory.count - capacity)
            downHistory.append(down); downHistory.removeFirst(downHistory.count - capacity)
            longUp.append(up)
            longDown.append(down)
        }
        last = (c.rx, c.tx, now)
        onUpdate?()
    }

    static func readCounters() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let total = len

        buf.withUnsafeBytes { raw in
            var off = 0
            let hdrSize = MemoryLayout<if_msghdr>.size
            let hdr2Size = MemoryLayout<if_msghdr2>.size
            while off + hdrSize <= total {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + hdr2Size <= total {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    let flags = h2.ifm_flags
                    if (flags & IFF_LOOPBACK) == 0, (flags & IFF_UP) != 0,
                       if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        if !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) {
                            rx &+= h2.ifm_data.ifi_ibytes
                            tx &+= h2.ifm_data.ifi_obytes
                        }
                    }
                }
                off += msgLen
            }
        }
        return (rx, tx)
    }

    /// "12 KB/s", "3.4 MB/s" (or bits when `bits` is true). Decimal (1000) units like macOS.
    static func format(_ bytesPerSec: Double, bits: Bool) -> String {
        let v = bits ? bytesPerSec * 8 : bytesPerSec
        let suffix = bits ? "b/s" : "B/s"
        let k = v / 1000
        if k < 10 { return String(format: "%.1f K", k) + suffix }
        if k < 1000 { return String(format: "%.0f K", k) + suffix }
        let m = k / 1000
        if m < 100 { return String(format: "%.1f M", m) + suffix }
        if m < 1000 { return String(format: "%.0f M", m) + suffix }
        return String(format: "%.1f G", m / 1000) + suffix
    }
}
