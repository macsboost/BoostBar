import AppKit
import ApplicationServices

/// Inverts scroll-wheel direction system-wide with a CGEvent tap.
/// Needs Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility).
final class ScrollReverser {
    var reverseTrackpad = false
    var reverseHorizontal = false
    var onStateChange: (() -> Void)?

    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?

    var isRunning: Bool { tap != nil }
    var isWaitingForPermission: Bool { permissionTimer != nil }
    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func promptForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard tap == nil else { return }
        guard Self.hasPermission else {
            Self.promptForPermission()
            waitForPermission()
            return
        }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            waitForPermission()
            return
        }
        tap = newTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        onStateChange?()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        onStateChange?()
    }

    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, Self.hasPermission else { return }
            t.invalidate()
            self.permissionTimer = nil
            self.start()
        }
        onStateChange?()
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate static func invert(_ e: CGEvent, vertical: Bool) {
        let d: CGEventField = vertical ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let f: CGEventField = vertical ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let p: CGEventField = vertical ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let dv = e.getIntegerValueField(d)
        let fv = e.getDoubleValueField(f)
        let pv = e.getIntegerValueField(p)
        e.setIntegerValueField(d, value: -dv)
        e.setDoubleValueField(f, value: -fv)
        e.setIntegerValueField(p, value: -pv)
    }
}

private func scrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let r = Unmanaged<ScrollReverser>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        r.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    // Trackpads (and Magic Mouse) send "continuous" scroll events; classic wheels don't.
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    if continuous && !r.reverseTrackpad { return Unmanaged.passUnretained(event) }

    ScrollReverser.invert(event, vertical: true)
    if r.reverseHorizontal { ScrollReverser.invert(event, vertical: false) }
    return Unmanaged.passUnretained(event)
}
