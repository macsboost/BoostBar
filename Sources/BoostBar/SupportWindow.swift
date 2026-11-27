import AppKit

/// "About BoostBar" + energydrinkware support page.
/// Shown once after the first install, and any time from the menu.
final class SupportWindow: NSObject, NSWindowDelegate {
    static let shared = SupportWindow()

    static let amount = "4.95"
    static let payEmail = "mac@supermac.net"
    static let venmoUser = "john-mcalpine-16"
    /// Card payments via Stripe, hosted on biz-cord.com (that page decides which Stripe link to use).
    static let stripeURL = "https://biz-cord.com/boostbar/donate"

    private static let shownKey = "supportShownOnce"

    struct Link { let title: String; let url: String }
    static let sites: [Link] = [
        Link(title: "macsboost.com", url: "https://macsboost.com"),
        Link(title: "ssi-d.com", url: "https://ssi-d.com"),
        Link(title: "x1racing.com", url: "https://x1racing.com"),
        Link(title: "buildflyingcars.com", url: "https://buildflyingcars.com"),
        Link(title: "biz-cord.com", url: "https://biz-cord.com"),
    ]

    static let socials: [Link] = [
        Link(title: "@realx1racing", url: "https://x.com/realx1racing"),
        Link(title: "@macsboost", url: "https://x.com/macsboost"),
        Link(title: "@solarsi_d", url: "https://x.com/solarsi_d"),
    ]

    static let tmogURL = "https://tmog.org"

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

#if !APPSTORE
    @objc private func payPayPal() {
        NotificationCenter.default.post(name: .boostBarTipClicked, object: nil)
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
        NotificationCenter.default.post(name: .boostBarTipClicked, object: nil)
        var c = URLComponents(string: "https://venmo.com/\(Self.venmoUser)")!
        c.queryItems = [
            .init(name: "txn", value: "pay"),
            .init(name: "amount", value: Self.amount),
            .init(name: "note", value: "BoostBar energy drink ⚡"),
        ]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    @objc private func payStripe() {
        NotificationCenter.default.post(name: .boostBarTipClicked, object: nil)
        var c = URLComponents(string: Self.stripeURL)!
        c.queryItems = [
            .init(name: "amount", value: Self.amount),
            .init(name: "app", value: "BoostBar"),
            .init(name: "version", value: Updater.currentVersion),
        ]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

#endif

#if APPSTORE
    @objc private func tipAppStore() { Task { await TipJar.buy() } }
#endif

    @objc private func openSocial(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.socials.count else { return }
        Self.open(Self.socials[sender.tag].url)
    }

    @objc private func openSite(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.sites.count else { return }
        Self.open(Self.sites[sender.tag].url)
    }

    @objc private func openTMOG() { Self.open(Self.tmogURL) }

    @objc private func closeWindow() { window?.close() }

    // MARK: Layout

    private func makeWindow() -> NSWindow {
        let width: CGFloat = 640
        let banner = Bundle.main.image(forResource: "SupportBanner")
        let bannerH: CGFloat = banner.map { width * $0.size.height / max($0.size.width, 1) } ?? 0
        let bodyH: CGFloat = 326
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
        #if APPSTORE
        let blurbText = "It's free. If you like it, buy Mac an energy drink — it keeps the boost coming.\nBy Mac McAlpine · MacsBoost"
        #else
        let blurbText = "It's free. If you like it, buy Mac an energy drink — $\(Self.amount) keeps the boost coming.\nBy Mac McAlpine · MacsBoost"
        #endif
        let blurb = NSTextField(wrappingLabelWithString: blurbText)
        blurb.alignment = .center
        blurb.font = .systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor
        blurb.frame = NSRect(x: 40, y: y, width: width - 80, height: 40)
        content.addSubview(blurb)

        // Pay buttons
        y -= 56
#if APPSTORE
        let tip = NSButton(title: "Buy Mac an Energy Drink ⚡", target: self, action: #selector(tipAppStore))
        tip.bezelStyle = .rounded
        tip.controlSize = .large
        tip.bezelColor = .systemGreen
        tip.contentTintColor = .white
        tip.font = .systemFont(ofSize: 15, weight: .semibold)
        tip.frame = NSRect(x: (width - 320) / 2, y: y, width: 320, height: 40)
        content.addSubview(tip)
        Task { @MainActor in
            if let price = await TipJar.displayPrice() { tip.title = "Buy Mac an Energy Drink ⚡  \(price)" }
        }
        var x: CGFloat = 0

        y -= 26
        let hint = NSTextField(labelWithString: "Tips are handled securely by the App Store and don’t unlock anything — just thanks.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 20, y: y, width: width - 40, height: 16)
        content.addSubview(hint)

#else
        let pays: [(String, Selector, NSColor, String)] = [
            ("PayPal  $\(Self.amount)", #selector(payPayPal), NSColor(srgbRed: 0, green: 0.44, blue: 0.73, alpha: 1),
             "Pay $\(Self.amount) to \(Self.payEmail) with PayPal"),
            ("Venmo  $\(Self.amount)", #selector(payVenmo), NSColor(srgbRed: 0.0, green: 0.55, blue: 1.0, alpha: 1),
             "Pay $\(Self.amount) to @\(Self.venmoUser) on Venmo"),
            ("Card  $\(Self.amount)", #selector(payStripe), NSColor(srgbRed: 0.39, green: 0.36, blue: 1.0, alpha: 1),
             "Pay $\(Self.amount) by card (Stripe) on biz-cord.com"),
        ]
        let bw: CGFloat = 140, gap: CGFloat = 12
        var x = (width - (bw * CGFloat(pays.count) + gap * CGFloat(pays.count - 1))) / 2
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
        let hint = NSTextField(labelWithString: "Card payments are processed by Stripe on biz-cord.com.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 20, y: y, width: width - 40, height: 16)
        content.addSubview(hint)

#endif
        // Site links
        y -= 40
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
        let totalW = linkButtons.reduce(0) { $0 + $1.frame.width } + CGFloat(linkButtons.count - 1) * 18
        x = (width - totalW) / 2
        for b in linkButtons {
            b.frame.origin = NSPoint(x: x, y: y)
            content.addSubview(b)
            x += b.frame.width + 18
        }

        // Follow on X
        y -= 26
        let follow = NSTextField(labelWithString: "Follow on 𝕏:")
        follow.font = .systemFont(ofSize: 12)
        follow.textColor = .secondaryLabelColor
        follow.sizeToFit()
        var socialButtons: [NSButton] = []
        for (i, s) in Self.socials.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(openSocial(_:)))
            b.isBordered = false
            b.tag = i
            b.attributedTitle = NSAttributedString(string: s.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            b.toolTip = s.url
            b.sizeToFit()
            socialButtons.append(b)
        }
        let socialW = follow.frame.width + 10 + socialButtons.reduce(0) { $0 + $1.frame.width } + CGFloat(socialButtons.count - 1) * 16
        x = (width - socialW) / 2
        follow.frame.origin = NSPoint(x: x, y: y + 2)
        content.addSubview(follow)
        x += follow.frame.width + 10
        for b in socialButtons {
            b.frame.origin = NSPoint(x: x, y: y)
            content.addSubview(b)
            x += b.frame.width + 16
        }

        // Credit: HDD LED inspiration
        let credit = NSMutableAttributedString(string: "Thanks to Dave Plummer for the HDD LED inspiration — check out ", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        credit.append(NSAttributedString(string: "TMOG (Task Manager OG)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        let creditButton = NSButton(title: "", target: self, action: #selector(openTMOG))
        creditButton.isBordered = false
        creditButton.attributedTitle = credit
        creditButton.toolTip = Self.tmogURL
        creditButton.sizeToFit()
        creditButton.frame.origin = NSPoint(x: (width - creditButton.frame.width) / 2, y: 60)
        content.addSubview(creditButton)

        let footer = NSTextField(labelWithString: "Free to use either way — may the boost be with you!")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: 20, y: 30, width: 480, height: 16)
        content.addSubview(footer)

        let privacy = NSTextField(labelWithString:
            "BoostBar sends biz-cord.com one anonymous install count per version (no personal info). Turn it off in the menu.")
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = .tertiaryLabelColor
        privacy.frame = NSRect(x: 20, y: 12, width: 500, height: 14)
        privacy.lineBreakMode = .byTruncatingTail
        content.addSubview(privacy)

        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.frame = NSRect(x: width - 20 - 90, y: 14, width: 90, height: 32)
        content.addSubview(close)

        w.contentView = content
        return w
    }
}
