# BoostBar

A small native macOS menu bar app from [MacsBoost](https://macsboost.com). It has no Dock icon and uses about 1% CPU or less.

```
 ● ▕▔▔▔▔▔▔▔▔▔▔▏ ▲ 42 KB/s
   ▕▁▁▁▁▁▁▁▁▁▁▏ ▼ 1.3 MB/s
```

- **Live bandwidth graph:** the last 30 seconds of traffic in one box. Upload (red) grows up from the center line and download (blue) grows down. The current rates sit beside the graph. You can switch between KB/s and Kb/s.
- **Reverse mouse scrolling:** flips the wheel direction in every app. You can keep the trackpad's natural scrolling, or reverse it too, plus optional horizontal scrolling.
- **Keep Mac awake:** one click (⌘K in the menu) keeps the Mac awake indefinitely, or pick 15 min to 8 h. You can keep the display on too. No admin rights needed.
- **Stay awake with the lid closed:** toggles `pmset -a disablesleep`. It needs admin rights, so macOS asks for your password. Or turn on **Lid Toggle Without Password**. That installs a sudoers rule for your user that allows only `pmset -a disablesleep 0|1`.
- **Launch at login:** a checkbox in the menu that uses the native macOS login-item API.
- **Self-updating:** checks GitHub Releases at launch, or when you pick **Check for Updates…**. It can download, swap, and relaunch in one click.

A dot left of the graph shows the sleep state. Yellow means "Keep awake" is on. Orange means sleep is disabled even with the lid closed.

## Install

Requires macOS 13 Ventura or newer. Runs natively on Apple Silicon and Intel.

```sh
curl -L https://github.com/macsboost/BoostBar/releases/latest/download/BoostBar.zip -o /tmp/BoostBar.zip
ditto -x -k /tmp/BoostBar.zip /Applications
open /Applications/BoostBar.app
```

You can also download `BoostBar.zip` from [Releases](https://github.com/macsboost/BoostBar/releases) and drag the app into **/Applications**. The app is ad-hoc signed, not notarized, so the first time you open a browser-downloaded copy, right-click it and choose **Open**. You can also run `xattr -dr com.apple.quarantine /Applications/BoostBar.app`.

Keep the app in /Applications. Launch at login and in-place updates need it there.

### Permissions

- **Reverse scrolling** needs **System Settings ▸ Privacy & Security ▸ Accessibility ▸ BoostBar**. The menu shows a shortcut if the permission is missing.
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

## License

MIT
