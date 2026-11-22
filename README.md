<p align="center">
  <img src="Resources/AppIcon-1024.png" width="160" alt="BoostBar app icon">
</p>

<h1 align="center">BoostBar</h1>

<p align="center">
  <a href="https://github.com/macsboost/BoostBar/releases/latest/download/BoostBar.zip">
    <img src="https://img.shields.io/badge/⬇%20Download%20BoostBar-FREE%20for%20macOS-56BE37?style=for-the-badge&labelColor=0e0f0e" height="56" alt="Download BoostBar — free for macOS">
  </a>
</p>

<p align="center">
  <b><a href="https://github.com/macsboost/BoostBar/releases/latest/download/BoostBar.zip">Download the latest BoostBar.zip</a></b> · free · macOS 13 or later · Apple silicon &amp; Intel · signed &amp; notarized by Apple<br>
  <sub>Unzip, drag <b>BoostBar</b> to Applications, open it. It lives in your menu bar. <a href="https://github.com/macsboost/BoostBar/releases">All versions</a></sub>
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/macsboost/BoostBar?label=latest&color=74FB4C&labelColor=0e0f0e" alt="Latest version">
  <img src="https://img.shields.io/github/downloads/macsboost/BoostBar/total?color=56BE37&labelColor=0e0f0e" alt="Downloads">
</p>

---

A small native macOS menu bar app from [MacsBoost](https://macsboost.com). It has no Dock icon and uses about 1% CPU or less.

```
 ● ▕▔▔▔▔▔▔▔▔▔▔▏ ▲ 42 KB/s
   ▕▁▁▁▁▁▁▁▁▁▁▏ ▼ 1.3 MB/s
```

- **Live bandwidth graph:** the last 30 seconds of traffic in one box. Upload (red) grows up from the center line and download (blue) grows down. The current rates sit beside the graph. You can switch between KB/s and Kb/s.
- **Battery power readout:** shows how many watts are going into the battery (green **IN**) or out of it (orange **OUT**). Hover over it to see the estimated time until full or empty, plus what the power adapter is supplying on Apple Silicon Macs.
- **Googly eyes:** a pair of eyes (or a single cyclops eye) that follow your mouse from the menu bar, with springy pupils and the occasional blink. Small, medium or large.
- **Settings window** (⌘, from the menu) with tabs for General, Sleep, Network, Battery, Disks, Eyes and Scrolling. Keep Awake stays in the menu for one-click access.
- **Drag to rearrange:** click and drag any piece of BoostBar in the menu bar (eyes, network, battery, disk lights) left or right to change the order. Settings ▸ General ▸ Reset Order puts it back.
- **Choose what's shown:** the network graph and the battery readout can each be turned on or off from the menu.
- **Reverse mouse scrolling:** flips the wheel direction in every app. You can keep the trackpad's natural scrolling, or reverse it too, plus optional horizontal scrolling.
- **Keep Mac awake:** one click (⌘K in the menu) keeps the Mac awake indefinitely, or pick 15 min to 8 h. You can keep the display on too. No admin rights needed.
- **Stay awake with the lid closed:** toggles `pmset -a disablesleep`. It needs admin rights, so macOS asks for your password. Or turn on **Lid Toggle Without Password**. That installs a sudoers rule for your user that allows only `pmset -a disablesleep 0|1`.
- **Launch at login:** a checkbox in the menu that uses the native macOS login-item API.
- **Self-updating:** checks GitHub Releases at launch, or when you pick **Check for Updates…**. It can download, swap, and relaunch in one click.

A dot left of the graph shows the sleep state. Yellow means "Keep awake" is on. Orange means sleep is disabled even with the lid closed.

## Flying Cars screen saver ✈️

BoostBar ships with **BoostBar Flying Cars**, a screen saver in the spirit of the classic flying toasters. X1 SkyRacers fly across the screen in a loose flock with their rotors and thruster fans spinning, painted in MacsBoost, Yonder 01 and XXONE 51 liveries. Open **Settings ▸ Screen Saver** to preview it, install it or start it now. To pick liveries, number of cars, speed and stars, go to System Settings ▸ Screen Saver ▸ BoostBar Flying Cars ▸ Options. (Direct download only.)

## Updates

BoostBar checks GitHub for a newer release when it starts, and you can check any time from the menu. Turn on **Settings ▸ General ▸ Install updates automatically** (or tick "Install future updates automatically" on the update prompt) and new versions are downloaded, verified as Apple-notarized and signed by MacsBoost, swapped in and relaunched with no prompt.

## Dizzy eyes

On MacBooks with Apple silicon, give the Mac a few firm shakes: the googly eyes squeeze shut while it's shaking, then pop open with their pupils spinning. Bumps, carrying it around and car rides don't trigger it. BoostBar reads the MacBook's built-in motion sensor (the undocumented IMU behind the Sensor Processing Unit) only while this is turned on — **Settings ▸ Eyes ▸ Shake the Mac to make them dizzy**. Direct download only.

## Hot corners

In **Settings ▸ Sleep ▸ Hot Corners**, choose a screen corner to toggle **Keep Awake** and one to **Sleep now**. Rest the pointer in the corner for a moment, and a small badge confirms the action.

## Install

Requires macOS 13 Ventura or newer. Runs natively on Apple Silicon and Intel.

```sh
curl -L https://github.com/macsboost/BoostBar/releases/latest/download/BoostBar.zip -o /tmp/BoostBar.zip
ditto -x -k /tmp/BoostBar.zip /Applications
open /Applications/BoostBar.app
```

You can also download `BoostBar.zip` from [Releases](https://github.com/macsboost/BoostBar/releases) and drag the app into **/Applications**. Release builds are signed with a Developer ID and notarized by Apple when the signing secrets below are set. Until then they are ad-hoc signed: right-click the app and choose **Open** the first time, or run `xattr -dr com.apple.quarantine /Applications/BoostBar.app`.

Keep the app in /Applications. Launch at login and in-place updates need it there.

### Permissions

- **Reverse scrolling** needs **System Settings ▸ Privacy & Security ▸ Accessibility ▸ BoostBar**. Whenever reverse scrolling is on but this permission is off (first run, after an update, or if it gets switched off), BoostBar shows a guide picture of exactly which switch to turn on, with a button that opens that settings page. The guide closes itself once the permission is on.
  Because builds are ad-hoc signed, macOS may forget this permission after an update. If scrolling stops reversing, toggle BoostBar off and on in that list, or remove it and add it again.
- **Lid-closed sleep** asks for your admin password each time unless the password-free rule is installed.

## Notes

- Lid-closed sleep uses `pmset disablesleep`, a system-wide setting that **stays on after you quit or restart** until you turn it off. Don't put a running Mac in a bag with it on.
- Keep Awake uses an IOKit power assertion. It ends when you turn it off, when the timer runs out, or when BoostBar quits.
- Mouse vs. trackpad is detected from the scroll event's "continuous" flag. A Magic Mouse counts as a trackpad, so turn on "Include Trackpad / Magic Mouse" if you use one.
- Bandwidth counts physical interfaces (Wi-Fi, Ethernet, USB/Thunderbolt). It skips loopback and VPN tunnel interfaces so traffic isn't counted twice.
- "Launch at Login" starts BoostBar when you log in. If your Mac logs in automatically, it starts at boot.

## Build from source

```sh
git clone https://github.com/macsboost/BoostBar && cd BoostBar
./scripts/build-app.sh          # -> dist/BoostBar.app (native arch)
UNIVERSAL=1 ./scripts/build-app.sh   # arm64 + x86_64, needs full Xcode
```

## Releasing

Bump `VERSION` (e.g. `1.0.1`) and push to `main`. GitHub Actions builds a universal `BoostBar.zip` and publishes release `v1.0.1`. Running copies of the app pick it up the next time they check. Pushing a `v*` tag works too.

## Code signing & notarization (CI)

The workflow signs with a **Developer ID Application** certificate and notarizes with an App Store Connect API key when these repository secrets exist (Settings ▸ Secrets and variables ▸ Actions):

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | base64 of the exported Developer ID Application `.p12` (cert + private key) |
| `MACOS_CERT_PASSWORD` | the password you set when exporting the `.p12` |
| `APPLE_API_KEY_P8` | contents of `AuthKey_XXXXXXXXXX.p8` (raw text or base64) |
| `APPLE_API_KEY_ID` | the key's 10-character Key ID |
| `APPLE_API_ISSUER_ID` | the Issuer ID (UUID) shown above the keys list |

Without them, builds fall back to ad-hoc signing.

## Energydrinkware ⚡

BoostBar is free. If you like it, buy me an energy drink ($4.95):
[PayPal](https://www.paypal.com/cgi-bin/webscr?cmd=_xclick&business=mac@supermac.net&item_name=BoostBar%20energy%20drink&amount=4.95&currency_code=USD&no_shipping=1) ·
[Venmo](https://venmo.com/u/john-mcalpine-16) ·
Apple Cash to mac@supermac.net ·
[Card (Stripe)](https://biz-cord.com/boostbar/donate)

More from MacsBoost: [macsboost.com](https://macsboost.com) · [ssi-d.com](https://ssi-d.com) · [x1racing.com](https://x1racing.com) · [buildflyingcars.com](https://buildflyingcars.com) · [biz-cord.com](https://biz-cord.com)

### Thanks

Thanks to Dave Plummer for the HDD LED inspiration. Check out [TMOG (Task Manager OG)](https://tmog.org).

### Install count

BoostBar sends one anonymous message to biz-cord.com per version per Mac. It contains a random ID, the app version, the macOS version and the CPU type, with no personal info. Turn it off with **Share Anonymous Install Count** in the menu. The server side is described in [docs/biz-cord-endpoints.md](docs/biz-cord-endpoints.md).

## License

MIT
