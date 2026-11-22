import AppKit

/// "About BoostBar" + energydrinkware support page.
/// Shown once after the first install, and any time from the menu.
final class SupportWindow: NSObject, NSWindowDelegate {
    static let shared = SupportWindow()

    static let amount = "4.95"
    static let payEmail = "mac@supermac.net"
    static let venmoUser = "john-mcalpine-16"

    private static let shownKey = "supportShownOnce"

    struct Link { let title: String; let url: String }
    static let sites: [Link] = [
        Link(title: "macsboost.com", url: "https://macsboost.com"),
        Link(title: "ssi-d.com", url: "https://ssi-d.com"),
        Link(title: "x1racing.com", url: "https://x1racing.com"),
        Link(title: "buildflyingcars.com", url: "https://buildflyingcars.com"),
    ]

    private var window: NSWindow?

    /// Call at launch: pops the window up the first time BoostBar runs.
    func showIfFirstLaunch() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.shownKey) else { return }
        d.set(true, forKey: Self.shownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.show() }
    }

    func show() {
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Payment / link actions

    private static func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    @objc private func payPayPal() {
        var c = URLComponents(string: "https://www.paypal.com/cgi-bin/webscr")!
        c.queryItems = [
            .init(name: "cmd", value: "_xclick"),
            .init(name: "business", value: Self.payEmail),
            .init(name: "item_name", value: "BoostBar energy drink"),
            .init(name: "amount", value: Self.amount),
            .init(name: "currency_code", value: "USD"),
            .init(name: "no_shipping", value: "1"),
        ]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    @objc private func payVenmo() {
        var c = URLComponents(string: "https://venmo.com/\(Self.venmoUser)")!
        c.queryItems = [
            .init(name: "txn", value: "pay"),
            .init(name: "amount", value: Self.amount),
            .init(name: "note", value: "BoostBar energy drink ⚡"),
        ]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    @objc private func payAppleCash() {
        // Apple Cash is sent from Messages: open a conversation to the recipient,
        // then the $ (Apple Cash) button sends the amount.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.amount, forType: .string)
        Self.open("imessage:\(Self.payEmail)")
    }

    @objc private func openSite(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.sites.count else { return }
        Self.open(Self.sites[sender.tag].url)
    }

    @objc private func closeWindow() { window?.close() }

    // MARK: Layout

    private func makeWindow() -> NSWindow {
        let width: CGFloat = 640
        let banner = Bundle.main.image(forResource: "SupportBanner")
        let bannerH: CGFloat = banner.map { width * $0.size.height / max($0.size.width, 1) } ?? 0
        let bodyH: CGFloat = 300
        let size = NSSize(width: width, height: bannerH + bodyH)

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "About BoostBar"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: size))

        // Banner image across the top
        if let banner {
            let iv = NSImageView(frame: NSRect(x: 0, y: bodyH, width: width, height: bannerH))
            iv.image = banner
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.toolTip = "MacsBoost — Ultimate Energy"
            content.addSubview(iv)
        }

        var y = bodyH - 44
        let title = NSTextField(labelWithString: "BoostBar \(Updater.currentVersion) is energydrinkware ⚡")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: y, width: width - 40, height: 28)
        content.addSubview(title)

        y -= 44
        let blurb = NSTextField(wrappingLabelWithString:
            "It's free. If you like it, buy me an energy drink — $\(Self.amount) keeps the boost coming.\nBy John McAlpine · MacsBoost")
        blurb.alignment = .center
        blurb.font = .systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor
        blurb.frame = NSRect(x: 40, y: y, width: width - 80, height: 40)
        content.addSubview(blurb)

        // Pay buttons
        y -= 56
        let pays: [(String, Selector, NSColor, String)] = [
            ("Apple Cash  $\(Self.amount)", #selector(payAppleCash), .systemGreen,
             "Opens Messages to \(Self.payEmail). Tap the Apple Cash (＄) button and send $\(Self.amount) — the amount is on your clipboard."),
            ("PayPal  $\(Self.amount)", #selector(payPayPal), NSColor(srgbRed: 0, green: 0.44, blue: 0.73, alpha: 1),
             "Pay $\(Self.amount) to \(Self.payEmail) with PayPal"),
            ("Venmo  $\(Self.amount)", #selector(payVenmo), NSColor(srgbRed: 0.0, green: 0.55, blue: 1.0, alpha: 1),
             "Pay $\(Self.amount) to @\(Self.venmoUser) on Venmo"),
        ]
        let bw: CGFloat = 176, gap: CGFloat = 14
        var x = (width - (bw * 3 + gap * 2)) / 2
        for (label, sel, color, tip) in pays {
            let b = NSButton(title: label, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.bezelColor = color
            b.contentTintColor = .white
            b.font = .systemFont(ofSize: 14, weight: .semibold)
            b.toolTip = tip
            b.frame = NSRect(x: x, y: y, width: bw, height: 40)
            content.addSubview(b)
            x += bw + gap
        }

        y -= 26
        let hint = NSTextField(labelWithString: "Apple Cash opens Messages to \(Self.payEmail) — tap ＄ and send $\(Self.amount).")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 20, y: y, width: width - 40, height: 16)
        content.addSubview(hint)

        // Site links
        y -= 46
        let linkFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        var linkButtons: [NSButton] = []
        for (i, site) in Self.sites.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(openSite(_:)))
            b.isBordered = false
            b.tag = i
            b.attributedTitle = NSAttributedString(string: site.title, attributes: [
                .font: linkFont, .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            b.toolTip = site.url
            b.sizeToFit()
            linkButtons.append(b)
        }
        let totalW = linkButtons.reduce(0) { $0 + $1.frame.width } + CGFloat(linkButtons.count - 1) * 26
        x = (width - totalW) / 2
        for b in linkButtons {
            b.frame.origin = NSPoint(x: x, y: y)
            content.addSubview(b)
            x += b.frame.width + 26
        }

        let footer = NSTextField(labelWithString: "Free to use either way — thanks for the boost!")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: 20, y: 22, width: 360, height: 16)
        content.addSubview(footer)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.frame = NSRect(x: width - 20 - 90, y: 14, width: 90, height: 32)
        content.addSubview(close)

        w.contentView = content
        return w
    }
}
