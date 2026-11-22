#if !APPSTORE
import Foundation
import IOKit
import IOKit.hid

/// Detects a deliberate shake of the MacBook using the built-in (undocumented) motion sensor on
/// Apple silicon MacBooks — the SPU's IMU exposed as AppleSPUHIDDevice, vendor page 0xFF00, usage 3.
/// Reports are 22 bytes with x/y/z as little-endian Int32 at offsets 6/10/14, in units of 1/65536 g.
///
/// A "shake" is several quick back-and-forth swings on one axis; a single bump, a car ride
/// (low, slow, one-sided swings), tilting or carrying the Mac doesn't count.
final class ShakeDetector {
    /// true when a shake starts, false when it has settled down.
    var onShake: ((Bool) -> Void)?
    private(set) var isRunning = false
    /// nil until we know; false if this Mac has no readable motion sensor.
    private(set) var available: Bool?

    // tuning
    private let peakG = 0.5          // a swing has to pass ±0.5 g (beyond gravity)
    private let swingsNeeded = 5     // alternating swings in a row on the same axis
    private let maxGap = 0.45        // seconds between swings
    private let minGap = 0.05
    private let settleG = 0.25       // shake is over once motion stays below this…
    private let settleTime = 0.55    // …for this long

    private var device: IOHIDDevice?
    private var accelDrivers: [io_service_t] = []
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    private var gravity = [0.0, 0.0, 0.0]
    private var primed = false
    private var lastSample: TimeInterval = 0
    private var lastSign = [0, 0, 0]
    private var lastPeakAt = [0.0, 0.0, 0.0]
    private var swings = [0, 0, 0]
    private var shaking = false
    private var lastStrong: TimeInterval = 0
    private var gotData = false

    deinit { stop(); buffer.deallocate() }

    static var hasSensor: Bool {
        let s = findAccelServices()
        s.forEach { IOObjectRelease($0) }
        return !s.isEmpty
    }

    func start() {
        guard !isRunning else { return }
        let services = Self.findAccelServices()
        guard let svc = services.first else { available = false; return }

        // Wake the IMU: it stays silent until its driver gets these properties.
        accelDrivers = Self.drivers(for: svc)
        for d in accelDrivers {
            Self.setInt(d, "SensorPropertyReportingState", 1)
            Self.setInt(d, "SensorPropertyPowerState", 1)
            Self.setInt(d, "ReportInterval", 10_000) // µs → ~100 Hz
        }

        guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc) else {
            services.forEach { IOObjectRelease($0) }
            available = false
            return
        }
        services.forEach { IOObjectRelease($0) }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            available = false
            return
        }
        device = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buffer, 128, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            Unmanaged<ShakeDetector>.fromOpaque(ctx).takeUnretainedValue().handle(report, length)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        isRunning = true
        primed = false
        gotData = false
        // If nothing arrives, the sensor isn't usable on this Mac.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isRunning else { return }
            self.available = self.gotData
            if !self.gotData { self.stop() }
        }
    }

    func stop() {
        guard isRunning || device != nil else { return }
        if let dev = device {
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        for d in accelDrivers {
            Self.setInt(d, "ReportInterval", 0) // let the IMU go back to sleep
            IOObjectRelease(d)
        }
        accelDrivers = []
        isRunning = false
        if shaking { shaking = false; onShake?(false) }
    }

    // MARK: - samples

    private func handle(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard length >= 18 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSample < 0.008 { return } // ~100 Hz is plenty
        lastSample = now
        func axis(_ off: Int) -> Double {
            var v: Int32 = 0
            withUnsafeMutableBytes(of: &v) { $0.copyMemory(from: UnsafeRawBufferPointer(start: report + off, count: 4)) }
            return Double(Int32(littleEndian: v)) / 65536.0
        }
        let a = [axis(6), axis(10), axis(14)]
        gotData = true
        if !primed { gravity = a; primed = true; return }

        // Slow low-pass tracks gravity (and tilting); what's left is the motion.
        for i in 0..<3 { gravity[i] += (a[i] - gravity[i]) * 0.04 }
        let dyn = (0..<3).map { a[$0] - gravity[$0] }
        let mag = dyn.map(abs).max() ?? 0

        for i in 0..<3 {
            let v = dyn[i]
            guard abs(v) >= peakG else { continue }
            let sign = v > 0 ? 1 : -1
            if sign == lastSign[i] { continue }        // still the same swing
            let gap = now - lastPeakAt[i]
            if lastSign[i] != 0, gap >= minGap, gap <= maxGap {
                swings[i] += 1
            } else {
                swings[i] = 1
            }
            lastSign[i] = sign
            lastPeakAt[i] = now
            if !shaking, swings[i] >= swingsNeeded {
                shaking = true
                lastStrong = now
                onShake?(true)
            }
        }
        for i in 0..<3 where now - lastPeakAt[i] > maxGap { swings[i] = 0; lastSign[i] = 0 }

        if shaking {
            if mag > settleG { lastStrong = now }
            if now - lastStrong > settleTime {
                shaking = false
                swings = [0, 0, 0]
                lastSign = [0, 0, 0]
                onShake?(false)
            }
        }
    }

    // MARK: - IOKit helpers

    /// AppleSPUHIDDevice services that are the accelerometer (caller releases).
    private static func findAccelServices() -> [io_service_t] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [io_service_t] = []
        while case let s = IOIteratorNext(it), s != 0 {
            if intProp(s, "PrimaryUsagePage") == 0xFF00 && intProp(s, "PrimaryUsage") == 3 {
                out.append(s)
            } else {
                IOObjectRelease(s)
            }
        }
        return out
    }

    /// The AppleSPUHIDDriver that feeds this device (a child in the service plane); falls back to
    /// drivers advertising the accelerometer usage.
    private static func drivers(for device: io_service_t) -> [io_service_t] {
        var out: [io_service_t] = []
        var it: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(device, kIOServicePlane, &it) == KERN_SUCCESS {
            while case let c = IOIteratorNext(it), c != 0 {
                if IOObjectConformsTo(c, "AppleSPUHIDDriver") != 0 { out.append(c) } else { IOObjectRelease(c) }
            }
            IOObjectRelease(it)
        }
        if !out.isEmpty { return out }
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS {
            while case let s = IOIteratorNext(it), s != 0 {
                if intProp(s, "PrimaryUsagePage") == 0xFF00 && intProp(s, "PrimaryUsage") == 3 { out.append(s) } else { IOObjectRelease(s) }
            }
            IOObjectRelease(it)
        }
        return out
    }

    private static func intProp(_ s: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }

    private static func setInt(_ s: io_service_t, _ key: String, _ v: Int32) {
        var n = v
        if let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &n) {
            IORegistryEntrySetCFProperty(s, key as CFString, num)
        }
    }
}
#endif
