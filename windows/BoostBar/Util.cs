using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using Microsoft.Win32;

namespace BoostBar
{
    /// Fixed-size history buffer (oldest first).
    class History
    {
        public readonly int Capacity;
        readonly List<double> values;
        public History(int capacity) { Capacity = capacity; values = Enumerable.Repeat(0.0, capacity).ToList(); }
        public void Append(double v) { values.Add(v); if (values.Count > Capacity) values.RemoveRange(0, values.Count - Capacity); }
        public double Last => values.Count > 0 ? values[values.Count - 1] : 0;
        public double Peak => values.Count > 0 ? values.Max() : 0;
        public double Sum => values.Sum();
        public double[] Values => values.ToArray();
        public double[] Suffix(int n) => values.Skip(Math.Max(0, values.Count - n)).ToArray();
    }

    /// Named colors offered in Settings, matching the Mac palette.
    static class Palette
    {
        public static readonly (string Name, Color Color)[] Named =
        {
            ("White", Color.White),
            ("Grey", Color.FromArgb(142, 142, 147)),
            ("Red", Color.FromArgb(255, 59, 48)),
            ("Orange", Color.FromArgb(255, 149, 0)),
            ("Yellow", Color.FromArgb(255, 204, 0)),
            ("Green", Color.FromArgb(52, 199, 89)),
            ("Boost Green", Hex("#56BE37").Value),
            ("Lime", Hex("#74FB4C").Value),
            ("Teal", Color.FromArgb(48, 176, 199)),
            ("Blue", Color.FromArgb(0, 122, 255)),
            ("Purple", Color.FromArgb(175, 82, 222)),
            ("Pink", Color.FromArgb(255, 45, 85)),
        };

        public static readonly (string Name, string Up, string Down)[] TracePresets =
        {
            ("White", "White", "White"), ("MacsBoost Green", "Boost Green", "Lime"), ("Classic Red / Blue", "Red", "Blue"),
        };

        public static readonly Color SystemGreen = Color.FromArgb(52, 199, 89);
        public static readonly Color SystemOrange = Color.FromArgb(255, 149, 0);
        public static readonly Color SystemPink = Color.FromArgb(255, 45, 85);
        public static readonly Color SystemYellow = Color.FromArgb(255, 204, 0);

        public static Color? Hex(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            s = s.Trim().TrimStart('#');
            if (s.Length != 6 || !int.TryParse(s, NumberStyles.HexNumber, null, out var v)) return null;
            return Color.FromArgb((v >> 16) & 255, (v >> 8) & 255, v & 255);
        }

        public static string ToHex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

        public static Color Resolve(string stored, Color fallback)
        {
            if (stored == null) return fallback;
            foreach (var n in Named) if (n.Name == stored) return n.Color;
            return Hex(stored) ?? fallback;
        }
    }

    static class Fmt
    {
        static readonly CultureInfo C = CultureInfo.InvariantCulture;
        public enum NetUnit { Auto = 0, Kilo = 1, Mega = 2 }

        /// "12 KB/s", "3.4 MB/s" (or bits). Decimal (1000) units.
        public static string Rate(double bytesPerSec, bool bits, NetUnit unit = NetUnit.Auto)
        {
            var v = bits ? bytesPerSec * 8 : bytesPerSec;
            var suffix = bits ? "b/s" : "B/s";
            var k = v / 1000;
            if (unit == NetUnit.Mega)
            {
                var mm = k / 1000;
                if (mm < 10) return mm.ToString("0.00", C) + " M" + suffix;
                if (mm < 100) return mm.ToString("0.0", C) + " M" + suffix;
                if (mm < 1000) return mm.ToString("0", C) + " M" + suffix;
                return (mm / 1000).ToString("0.0", C) + " G" + suffix;
            }
            if (k < 10) return k.ToString("0.0", C) + " K" + suffix;
            if (k < 1000) return k.ToString("0", C) + " K" + suffix;
            var m = k / 1000;
            if (m < 100) return m.ToString("0.0", C) + " M" + suffix;
            if (m < 1000) return m.ToString("0", C) + " M" + suffix;
            return (m / 1000).ToString("0.0", C) + " G" + suffix;
        }

        public static string Bytes(double b)
        {
            string[] u = { "B", "KB", "MB", "GB", "TB", "PB" };
            var i = 0;
            while (b >= 1000 && i < u.Length - 1) { b /= 1000; i++; }
            return (i == 0 ? b.ToString("0", C) : b < 10 ? b.ToString("0.0", C) : b.ToString("0", C)) + " " + u[i];
        }

        public static string Watts(double w)
        {
            var a = Math.Abs(w);
            return a < 10 ? a.ToString("0.0", C) + "W" : a.ToString("0", C) + "W";
        }

        public static string Duration(int minutes)
        {
            int h = minutes / 60, m = minutes % 60;
            return h > 0 ? $"{h}h {m:00}m" : $"{m}m";
        }

        public static string Pct(double x) => (x * 100).ToString("0", C) + "%";
    }

    static class Theme
    {
        /// Is the taskbar light (dark text)? Windows draws the taskbar in the "system" theme, not the app theme.
        public static bool TaskbarIsLight
        {
            get
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                        return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
                }
                catch { return false; }
            }
        }

        public static bool IsWindows11 => Environment.OSVersion.Version.Build >= 22000;
    }
}
