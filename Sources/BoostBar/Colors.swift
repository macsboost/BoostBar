import AppKit

/// Named colors offered in menus and the Disk Lights window, plus hex (de)serialization for UserDefaults.
enum Palette {
    static let named: [(name: String, color: NSColor)] = [
        ("White", .white),
        ("Grey", .systemGray),
        ("Red", .systemRed),
        ("Orange", .systemOrange),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Boost Green", NSColor(hex: "#56BE37")!),
        ("Lime", NSColor(hex: "#74FB4C")!),
        ("Teal", .systemTeal),
        ("Blue", .systemBlue),
        ("Purple", .systemPurple),
        ("Pink", .systemPink),
    ]

    /// Upload/download trace presets offered in Settings ▸ Network.
    static let tracePresets: [(name: String, up: String, down: String)] = [
        ("White", "White", "White"),
        ("MacsBoost Green", "Boost Green", "Lime"),
        ("Classic Red / Blue", "Red", "Blue"),
    ]

    static func color(named name: String) -> NSColor? {
        named.first(where: { $0.name == name })?.color
    }

    /// Stored value is either a palette name ("White") or a hex string ("#33AAFF").
    static func resolve(_ stored: String?, default fallback: NSColor) -> NSColor {
        guard let stored else { return fallback }
        return color(named: stored) ?? NSColor(hex: stored) ?? fallback
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Fixed-size history buffer (oldest first).
struct History {
    let capacity: Int
    private(set) var values: [Double]

    init(capacity: Int) {
        self.capacity = capacity
        values = Array(repeating: 0, count: capacity)
    }

    mutating func append(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    var last: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
    func suffix(_ n: Int) -> [Double] { Array(values.suffix(n)) }
}
