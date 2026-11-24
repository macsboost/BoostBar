using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using Microsoft.Win32;

namespace BoostBar
{
    enum Segment { Eyes, Network, Battery, Disks, Cpu }
    enum Corner { None = 0, TopLeft, TopRight, BottomLeft, BottomRight }

    /// All user settings, kept in HKCU\Software\MacsBoost\BoostBar (same names and defaults as the Mac version).
    static class Prefs
    {
        public const string KeyPath = @"Software\MacsBoost\BoostBar";
        public static event Action Changed;
        static readonly CultureInfo C = CultureInfo.InvariantCulture;

        static object Raw(string k)
        {
            try { using (var r = Registry.CurrentUser.OpenSubKey(KeyPath)) return r?.GetValue(k); } catch { return null; }
        }

        public static bool Has(string k) => Raw(k) != null;

        static void Write(string k, object v, RegistryValueKind kind)
        {
            try { using (var r = Registry.CurrentUser.CreateSubKey(KeyPath)) r.SetValue(k, v, kind); } catch { }
        }

        public static void Notify() => Changed?.Invoke();

        public static bool GetBool(string k, bool def) { var v = Raw(k); try { return v == null ? def : Convert.ToInt32(v) != 0; } catch { return def; } }
        public static void SetBool(string k, bool v) { Write(k, v ? 1 : 0, RegistryValueKind.DWord); Notify(); }
        public static int GetInt(string k, int def) { var v = Raw(k); try { return v == null ? def : Convert.ToInt32(v); } catch { return def; } }
        public static void SetInt(string k, int v) { Write(k, v, RegistryValueKind.DWord); Notify(); }
        public static double GetDouble(string k, double def)
        {
            var v = Raw(k) as string;
            return v != null && double.TryParse(v, NumberStyles.Float, C, out var d) ? d : def;
        }
        public static void SetDouble(string k, double v) { Write(k, v.ToString("R", C), RegistryValueKind.String); Notify(); }
        public static string GetString(string k, string def) => Raw(k) as string ?? def;
        public static void SetString(string k, string v) { Write(k, v ?? "", RegistryValueKind.String); Notify(); }

        /// Fresh install: start with the googly eyes on and large, and medium disk LEDs.
        public static void RegisterDefaults()
        {
            if (!Has("supportShownOnce") && !Has("showEyes"))
            {
                Write("showEyes", 1, RegistryValueKind.DWord);
                Write("eyeSize", 2, RegistryValueKind.DWord);
                if (!Has("ledSize")) Write("ledSize", 1, RegistryValueKind.DWord);
            }
        }

        // Network
        public static bool ShowNetwork { get => GetBool("showNetwork", true); set => SetBool("showNetwork", value); }
        public static bool NetSplit { get => GetBool("networkGraphPerConnection", true); set => SetBool("networkGraphPerConnection", value); }
        public static bool UseBits { get => GetBool("useBits", false); set => SetBool("useBits", value); }
        public static Fmt.NetUnit NetUnit { get => GetInt("networkUnit", 0) == 2 ? Fmt.NetUnit.Mega : Fmt.NetUnit.Auto; set => SetInt("networkUnit", (int)value); }
        public static string UpColorName { get => GetString("netUpColor", "White"); set => SetString("netUpColor", value); }
        public static string DownColorName { get => GetString("netDownColor", "White"); set => SetString("netDownColor", value); }
        public static Color UpColor => Palette.Resolve(UpColorName, Color.White);
        public static Color DownColor => Palette.Resolve(DownColorName, Color.White);

        // Battery
        public static bool ShowBattery { get => GetBool("showBattery", BatteryMonitor.HasBattery); set => SetBool("showBattery", value); }

        // CPU
        public static bool ShowCPU { get => GetBool("showCPU", true); set => SetBool("showCPU", value); }
        /// 0 = half-round boost gauge, 1 = a bar per core (spectrum analyzer)
        public static int CpuStyle { get => GetInt("cpuStyle", 1); set => SetInt("cpuStyle", value); }
        public static double CpuRate { get => Clamp(GetDouble("cpuUpdatesPerSecond", 5), 1, 60); set => SetDouble("cpuUpdatesPerSecond", Clamp(value, 1, 60)); }
        public static double CpuBackdrop
        {
            get => Clamp(GetDouble("cpuBackdrop", -0.6), -1, 1);
            set => SetDouble("cpuBackdrop", Math.Abs(value) < 0.04 ? 0 : Clamp(value, -1, 1));
        }
        public static double CpuPeakHold { get => Clamp(GetDouble("cpuPeakHoldSeconds", 1.5), 0, 10); set => SetDouble("cpuPeakHoldSeconds", value < 0.2 ? 0 : Math.Min(10, value)); }

        // Disks
        public static bool ShowDisks { get => GetBool("showDisks", true); set => SetBool("showDisks", value); }
        public static int LedSize { get => Math.Min(2, Math.Max(0, GetInt("ledSize", 0))); set => SetInt("ledSize", value); }
        public static int LedDurationMs { get => GetInt("ledDurationMs", 35); set => SetInt("ledDurationMs", value); }
        public static readonly int[] LedDurations = { 10, 20, 35, 50, 75, 100, 150, 250, 500 };
        public static bool DiskEnabled(string key) => GetBool("disk.on." + key, true);
        public static void SetDiskEnabled(string key, bool on) => SetBool("disk.on." + key, on);
        public static string DiskColorName(string key, bool isInternal) => GetString("disk.color." + key, isInternal ? "Green" : "Blue");
        public static void SetDiskColorName(string key, string name) => SetString("disk.color." + key, name);

        // Eyes
        public static bool ShowEyes { get => GetBool("showEyes", false); set => SetBool("showEyes", value); }
        public static int EyeSize { get => Math.Min(2, Math.Max(0, GetInt("eyeSize", 1))); set => SetInt("eyeSize", value); }
        public static bool SingleEye { get => GetBool("singleEye", false); set => SetBool("singleEye", value); }
        public static bool Googly { get => GetBool("googlyEyes", true); set => SetBool("googlyEyes", value); }
        public static bool LazyEyes { get => GetBool("lazyEyes", false); set => SetBool("lazyEyes", value); }
        public static bool EyeBlink { get => GetBool("eyeBlink", true); set => SetBool("eyeBlink", value); }
        public static bool AllowCrossEye { get => GetBool("allowCrossEye", true); set => SetBool("allowCrossEye", value); }
        public static bool Bloodshot { get => GetBool("bloodshotEyes", false); set => SetBool("bloodshotEyes", value); }
        public static bool BloodshotAwake { get => GetBool("bloodshotWhenAwake", true); set => SetBool("bloodshotWhenAwake", value); }
        public static bool Pirate { get => GetBool("pirateEyes", false); set => SetBool("pirateEyes", value); }
        public static readonly string[] SizeNames = { "Small", "Medium", "Large" };

        // Layout
        public static bool VerticalLabels { get => GetBool("verticalLabels", false); set => SetBool("verticalLabels", value); }
        /// 0 = on the taskbar, 1 = a floating bar
        public static int Placement { get => GetInt("placement", 0); set => SetInt("placement", value); }
        public static int FloatX { get => GetInt("floatX", int.MinValue); set => SetInt("floatX", value); }
        public static int FloatY { get => GetInt("floatY", int.MinValue); set => SetInt("floatY", value); }

        public static readonly Segment[] DefaultOrder = { Segment.Eyes, Segment.Network, Segment.Battery, Segment.Cpu, Segment.Disks };
        public static Segment[] SegmentOrder
        {
            get
            {
                var saved = GetString("segmentOrder", "").Split(',')
                    .Select(s => Enum.TryParse<Segment>(s, true, out var g) ? (Segment?)g : null).Where(s => s.HasValue).Select(s => s.Value);
                var outp = new List<Segment>();
                foreach (var s in saved) if (!outp.Contains(s)) outp.Add(s);
                for (var i = 0; i < DefaultOrder.Length; i++)
                {
                    var s = DefaultOrder[i];
                    if (outp.Contains(s)) continue;
                    var at = i + 1 < DefaultOrder.Length ? outp.IndexOf(DefaultOrder[i + 1]) : -1;
                    if (at >= 0) outp.Insert(at, s); else outp.Add(s);
                }
                return outp.ToArray();
            }
            set => SetString("segmentOrder", string.Join(",", value.Select(s => s.ToString().ToLowerInvariant())));
        }

        // Sleep
        public static bool KeepDisplayAwake { get => GetBool("keepDisplayAwake", false); set => SetBool("keepDisplayAwake", value); }
        public static Corner CornerAwake { get => (Corner)GetInt("hotCornerKeepAwake", 0); set => SetInt("hotCornerKeepAwake", (int)value); }
        public static Corner CornerSleep { get => (Corner)GetInt("hotCornerSleepNow", 0); set => SetInt("hotCornerSleepNow", (int)value); }
        public static Corner CornerSaver { get => (Corner)GetInt("hotCornerScreenSaver", 0); set => SetInt("hotCornerScreenSaver", (int)value); }

        // Scrolling
        public static bool ReverseScroll { get => GetBool("reverseScroll", false); set => SetBool("reverseScroll", value); }
        public static bool ReverseHorizontal { get => GetBool("reverseHorizontal", false); set => SetBool("reverseHorizontal", value); }

        // Updates & privacy
        public static bool CheckOnLaunch { get => GetBool("checkUpdatesOnLaunch", true); set => SetBool("checkUpdatesOnLaunch", value); }
        public static bool AutoUpdate { get => GetBool("installUpdatesAutomatically", false); set => SetBool("installUpdatesAutomatically", value); }
        public static bool ShareInstallCount { get => GetBool("shareInstallCount", true); set => SetBool("shareInstallCount", value); }

        static double Clamp(double v, double lo, double hi) => Math.Min(hi, Math.Max(lo, v));
    }
}
