import Foundation
import Darwin
import SystemConfiguration

/// One network connection (Wi‑Fi, a LAN port, iPhone USB, …) with its own traffic history.
struct NetLink {
    enum Kind: Int { case ethernet, wifi, other }
    let id: String          // BSD name, e.g. en0
    var kind: Kind
    var name: String        // "Wi‑Fi", "USB 10/100/1000 LAN", …
    var short: String       // "Wi‑Fi", "LAN", "LAN 2", "iPhone"
    var symbol: String      // SF Symbol for the menu bar
    var up: [Double]
    var down: [Double]
    var longUp = History(capacity: 300)
    var longDown = History(capacity: 300)
    var active = false
    var currentUp: Double { up.last ?? 0 }
    var currentDown: Double { down.last ?? 0 }
}

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
    private var lastPer: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var table: [String: NetLink] = [:]
    private var scInfo: [String: (kind: NetLink.Kind, name: String, symbol: String)] = [:]
    private var scRefreshed: TimeInterval = 0

    /// Connections that are up and have an address, LAN first, then Wi‑Fi, then the rest.
    var activeLinks: [NetLink] {
        table.values.filter(\.active).sorted { ($0.kind.rawValue, $0.id.count, $0.id) < ($1.kind.rawValue, $1.id.count, $1.id) }
    }
    func link(_ id: String) -> NetLink? { table[id] }
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
        let ifs = Self.readInterfaces()
        let now = ProcessInfo.processInfo.systemUptime
        var rx: UInt64 = 0, tx: UInt64 = 0
        for i in ifs { rx &+= i.rx; tx &+= i.tx }
        if let l = last {
            let dt = max(now - l.t, 0.001)
            let up = tx >= l.tx ? Double(tx - l.tx) / dt : 0
            let down = rx >= l.rx ? Double(rx - l.rx) / dt : 0
            upHistory.append(up); upHistory.removeFirst(upHistory.count - capacity)
            downHistory.append(down); downHistory.removeFirst(downHistory.count - capacity)
            longUp.append(up)
            longDown.append(down)
        }
        updateLinks(ifs, dt: last.map { max(now - $0.t, 0.001) })
        last = (rx, tx, now)
        onUpdate?()
    }

    private func updateLinks(_ ifs: [Iface], dt: TimeInterval?) {
        let connected = Self.namesWithAddresses()
        if ifs.contains(where: { scInfo[$0.name] == nil }) || ProcessInfo.processInfo.systemUptime - scRefreshed > 60 {
            refreshInterfaceInfo()
        }
        var seen = Set<String>()
        for i in ifs {
            seen.insert(i.name)
            var l = table[i.name] ?? NetLink(id: i.name, kind: .other, name: i.name, short: i.name, symbol: "network",
                                             up: Array(repeating: 0, count: capacity), down: Array(repeating: 0, count: capacity))
            if let info = scInfo[i.name] { l.kind = info.kind; l.name = info.name; l.symbol = info.symbol }
            var up = 0.0, down = 0.0
            if let dt, let p = lastPer[i.name] {
                up = i.tx >= p.tx ? Double(i.tx - p.tx) / dt : 0
                down = i.rx >= p.rx ? Double(i.rx - p.rx) / dt : 0
            }
            lastPer[i.name] = (i.rx, i.tx)
            l.up.append(up); l.up.removeFirst(l.up.count - capacity)
            l.down.append(down); l.down.removeFirst(l.down.count - capacity)
            l.longUp.append(up); l.longDown.append(down)
            l.active = i.running && connected.contains(i.name)
            table[i.name] = l
        }
        for k in table.keys where !seen.contains(k) { table[k]?.active = false }

        // short labels: Wi‑Fi, LAN, LAN 2, iPhone…
        var count: [String: Int] = [:]
        for l in activeLinks {
            let base: String
            switch l.kind {
            case .wifi: base = "Wi‑Fi"
            case .ethernet: base = "LAN"
            case .other: base = Self.shortName(l.name)
            }
            count[base, default: 0] += 1
            table[l.id]?.short = count[base]! > 1 ? "\(base) \(count[base]!)" : base
        }
    }

    private func refreshInterfaceInfo() {
        scRefreshed = ProcessInfo.processInfo.systemUptime
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        for i in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(i) as String? ?? ""
            let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd
            let lower = name.lowercased()
            let kind: NetLink.Kind
            var symbol = "network"
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) || lower.contains("wi-fi") || lower.contains("airport") {
                kind = .wifi; symbol = "wifi"
            } else if lower.contains("iphone") || lower.contains("ipad") {
                kind = .other; symbol = "iphone"
            } else if lower.contains("bluetooth") {
                kind = .other; symbol = "antenna.radiowaves.left.and.right"
            } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                kind = .ethernet; symbol = "cable.connector"
            } else {
                kind = .other
            }
            scInfo[bsd] = (kind, name, symbol)
        }
    }

    private static func shortName(_ name: String) -> String {
        let l = name.lowercased()
        if l.contains("iphone") { return "iPhone" }
        if l.contains("ipad") { return "iPad" }
        if l.contains("bluetooth") { return "BT" }
        let word = name.split(separator: " ").first.map(String.init) ?? name
        return String(word.prefix(7))
    }

    /// Interfaces with a routable IPv4/IPv6 address (not just link-local).
    private static func namesWithAddresses() -> Set<String> {
        var out = Set<String>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr else { continue }
            let name = String(cString: a.pointee.ifa_name)
            if sa.pointee.sa_family == UInt8(AF_INET) {
                let v4 = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let b0 = UInt8(truncatingIfNeeded: v4), b1 = UInt8(truncatingIfNeeded: v4 >> 8)
                if !(b0 == 169 && b1 == 254) && b0 != 127 { out.insert(name) }
            } else if sa.pointee.sa_family == UInt8(AF_INET6) {
                let linkLocal = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s -> Bool in
                    let b = s.pointee.sin6_addr.__u6_addr.__u6_addr8
                    return (b.0 == 0xfe && (b.1 & 0xc0) == 0x80) || (b.0 == 0 && b.15 <= 1)
                }
                if !linkLocal { out.insert(name) }
            }
        }
        return out
    }

    struct Iface { let name: String; let rx: UInt64; let tx: UInt64; let running: Bool }

    static func readCounters() -> (rx: UInt64, tx: UInt64) {
        readInterfaces().reduce((UInt64(0), UInt64(0))) { ($0.0 &+ $1.rx, $0.1 &+ $1.tx) }
    }

    static func readInterfaces() -> [Iface] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return [] }

        var out: [Iface] = []
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
                            out.append(Iface(name: name, rx: h2.ifm_data.ifi_ibytes, tx: h2.ifm_data.ifi_obytes,
                                             running: (flags & IFF_RUNNING) != 0))
                        }
                    }
                }
                off += msgLen
            }
        }
        return out
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
