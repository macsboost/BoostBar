import Foundation
import IOKit.pwr_mgt

/// "Keep Awake": blocks idle sleep with an IOKit power assertion (no admin needed).
/// Released automatically when the app quits.
final class SleepManager {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var expiryTimer: Timer?

    private(set) var isPreventing = false
    private(set) var until: Date?
    var onChange: (() -> Void)?

    var keepDisplayAwake = false {
        didSet { if isPreventing { applyAssertions() } }
    }

    func prevent(for duration: TimeInterval?) {
        isPreventing = true
        applyAssertions()
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let duration {
            until = Date().addingTimeInterval(duration)
            let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in self?.allow() }
            RunLoop.main.add(t, forMode: .common)
            expiryTimer = t
        } else {
            until = nil
        }
        onChange?()
    }

    func allow() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        until = nil
        isPreventing = false
        releaseAssertions()
        onChange?()
    }

    private func applyAssertions() {
        releaseAssertions()
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "BoostBar: Keep Awake" as CFString, &id) == kIOReturnSuccess {
            systemAssertion = id
        }
        if keepDisplayAwake {
            var did: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "BoostBar: Keep Display Awake" as CFString, &did) == kIOReturnSuccess {
                displayAssertion = did
            }
        }
    }

    private func releaseAssertions() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }
}

#if !APPSTORE
/// "Stay awake with lid closed": wraps `pmset -a disablesleep 0|1`, which needs root.
/// Optionally installs a narrowly-scoped sudoers rule so toggling doesn't ask for a password.
enum LidSleep {
    static let sudoersPath = "/etc/sudoers.d/boostbar"

    /// Reads `SleepDisabled` from `pmset -g`.
    static var isDisabled: Bool {
        let out = Shell.run("/usr/bin/pmset", ["-g"]).out
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
        return false
    }

    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// Call on the main thread (may show the admin password dialog).
    @discardableResult
    static func set(disabled: Bool) -> Bool {
        let v = disabled ? "1" : "0"
        if helperInstalled,
           Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", v]).status == 0 {
            return true
        }
        return Shell.runAsAdmin("/usr/bin/pmset -a disablesleep \(v)",
                                prompt: "BoostBar wants to change lid-closed sleep.")
    }

    static func installHelper() -> Bool {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("boostbar-sudoers-\(UUID().uuidString)")
        do { try rule.write(to: tmp, atomically: true, encoding: .utf8) } catch { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let q = Shell.quote(tmp.path)
        return Shell.runAsAdmin(
            "/usr/sbin/visudo -cf \(q) && /usr/bin/install -m 0440 -o root -g wheel \(q) \(sudoersPath)",
            prompt: "BoostBar wants to allow lid-sleep toggling without a password.")
    }

    static func removeHelper() -> Bool {
        Shell.runAsAdmin("/bin/rm -f \(sudoersPath)", prompt: "BoostBar wants to remove its password-free lid-sleep rule.")
    }
}
#endif
