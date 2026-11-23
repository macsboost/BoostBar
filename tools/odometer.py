#!/usr/bin/env python3
"""Draw an old-school web hit counter as a mechanical odometer (SVG): black number wheels with white numerals,
a white last wheel, chrome bezel. The wheels roll up from 000000 to the count when the image loads.

  python3 tools/odometer.py 1234 odometer.svg
"""
import sys

n = max(0, int(sys.argv[1]))
out = sys.argv[2]
DIGITS = max(7, len(str(n)))
s = str(n).zfill(DIGITS)
W, H, GAP, PAD = 34, 48, 3, 12            # wheel size, gap, bezel padding
TOP = 26                                   # room for the label
width = PAD * 2 + DIGITS * W + (DIGITS - 1) * GAP
height = TOP + H + PAD * 2 + 16

o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="{n} visitors">',
     '<defs>',
     '<linearGradient id="bezel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f4f5f6"/><stop offset=".45" stop-color="#9a9da2"/><stop offset=".55" stop-color="#6d7075"/><stop offset="1" stop-color="#c9cbcf"/></linearGradient>',
     '<linearGradient id="drum" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#000" stop-opacity=".85"/><stop offset=".22" stop-color="#000" stop-opacity=".15"/><stop offset=".5" stop-color="#fff" stop-opacity=".10"/><stop offset=".78" stop-color="#000" stop-opacity=".15"/><stop offset="1" stop-color="#000" stop-opacity=".85"/></linearGradient>',
     '<linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".4" stop-color="#fff" stop-opacity="0"/></linearGradient>']
for i in range(DIGITS):
    x = PAD + i * (W + GAP)
    o.append(f'<clipPath id="c{i}"><rect x="{x}" y="{TOP + PAD}" width="{W}" height="{H}" rx="3"/></clipPath>')
o.append('</defs>')
o.append(f'<text x="{width / 2}" y="15" text-anchor="middle" font-family="Courier New, Courier, monospace" font-size="12" font-weight="bold" letter-spacing="3" fill="#8a8f96">YOU ARE VISITOR NO.</text>')
o.append(f'<rect x="1" y="{TOP + 1}" width="{width - 2}" height="{H + PAD * 2 - 2}" rx="9" fill="url(#bezel)" stroke="#55585c"/>')
o.append(f'<rect x="{PAD - 5}" y="{TOP + PAD - 5}" width="{width - PAD * 2 + 10}" height="{H + 10}" rx="5" fill="#0b0b0c" stroke="#2a2b2e"/>')
for i, ch in enumerate(s):
    d = int(ch)
    x = PAD + i * (W + GAP)
    last = i == DIGITS - 1
    bg, fg = ('#f2f0e6', '#111') if last else ('#17181a', '#f5f5f0')
    y0 = TOP + PAD
    o.append(f'<g clip-path="url(#c{i})">')
    o.append(f'<rect x="{x}" y="{y0}" width="{W}" height="{H}" fill="{bg}"/>')
    # the strip of numerals 0..d (plus the next one peeking for the last wheel), rolled so d sits in the window
    roll = d * H + (H * 0.18 if last else 0)
    dur = 0.9 + 0.25 * (DIGITS - i)
    o.append(f'<g transform="translate(0 {roll:.1f})">')
    if roll:
        o.append(f'<animateTransform attributeName="transform" type="translate" from="0 0" to="0 {roll:.1f}" dur="{dur:.2f}s" calcMode="spline" keyTimes="0;1" keySplines=".2 .7 .2 1" fill="freeze"/>')
    for k in range(0, d + 2):
        yy = y0 + H * 0.5 - k * H
        o.append(f'<text x="{x + W / 2}" y="{yy + 13:.1f}" text-anchor="middle" font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-size="36" font-weight="bold" fill="{fg}">{k % 10}</text>')
        o.append(f'<rect x="{x}" y="{yy - H / 2 - 0.5:.1f}" width="{W}" height="1" fill="#000" opacity=".5"/>')
    o.append('</g>')
    o.append(f'<rect x="{x}" y="{y0}" width="{W}" height="{H}" fill="url(#drum)"/>')
    o.append('</g>')
o.append(f'<rect x="{PAD - 5}" y="{TOP + PAD - 5}" width="{width - PAD * 2 + 10}" height="{H + 10}" rx="5" fill="url(#glass)"/>')
o.append(f'<text x="{width / 2}" y="{height - 3}" text-anchor="middle" font-family="Courier New, Courier, monospace" font-size="10" fill="#8a8f96">since Nov 2026 · best viewed in any browser</text>')
o.append('</svg>')
open(out, 'w').write('\n'.join(o) + '\n')
print(out, n)
