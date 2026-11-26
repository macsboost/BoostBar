using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BoostBar
{
    class BatteryReading
    {
        public enum Dir { Charging, Discharging, Idle }
        /// Positive = into the battery (charging), negative = out of it.
        public double Watts;
        public Dir Direction;
        public int? Percent;
        public int? MinutesRemaining;
        public bool ExternalConnected;
        public bool FullyCharged;
        public int? CycleCount;
        public int? HealthPercent;
        /// True for the short while after the charger is plugged in or pulled, while the driver's rate still
        /// points the old way: the reading follows the charger instead.
        public bool Estimated;
    }

    /// Reads the battery driver directly (IOCTL_BATTERY_QUERY_STATUS): the charge/discharge rate in milliwatts.
    static class BatteryMonitor
    {
        static readonly Guid BatteryClass = new Guid("72631e54-78a4-11d0-bcf7-00aa00b7b32a");
        const uint IOCTL_BATTERY_QUERY_TAG = 0x294040, IOCTL_BATTERY_QUERY_INFORMATION = 0x294044, IOCTL_BATTERY_QUERY_STATUS = 0x29404C;
        const uint POWER_ON_LINE = 1, DISCHARGING = 2, CHARGING = 4;
        const uint CAPACITY_RELATIVE = 0x40000000;
        const uint UNKNOWN_RATE = 0x80000000;

        static List<string> paths;
        static DateTime pathsAt = DateTime.MinValue;
        static readonly Dictionary<string, (uint caps, uint designed, uint full, uint cycles)> info = new Dictionary<string, (uint, uint, uint, uint)>();

        static bool? hasBattery;
        public static bool HasBattery
        {
            get
            {
                if (hasBattery == null)
                {
                    try
                    {
                        var s = SystemInformation.PowerStatus.BatteryChargeStatus;
                        hasBattery = (s & BatteryChargeStatus.NoSystemBattery) == 0 && s != BatteryChargeStatus.Unknown && DevicePaths().Count > 0;
                    }
                    catch { hasBattery = false; }
                }
                return hasBattery.Value;
            }
        }

        static List<string> DevicePaths()
        {
            if (paths != null && (DateTime.UtcNow - pathsAt).TotalSeconds < 60) return paths;
            var list = new List<string>();
            var g = BatteryClass;
            var set = Native.SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, Native.DIGCF_PRESENT | Native.DIGCF_DEVICEINTERFACE);
            if (set != IntPtr.Zero && set != new IntPtr(-1))
            {
                try
                {
                    for (uint i = 0; i < 8; i++)
                    {
                        var d = new Native.SP_DEVICE_INTERFACE_DATA { cbSize = Marshal.SizeOf(typeof(Native.SP_DEVICE_INTERFACE_DATA)) };
                        if (!Native.SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
                        Native.SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out var need, IntPtr.Zero);
                        if (need <= 0) continue;
                        var buf = Marshal.AllocHGlobal(need);
                        try
                        {
                            Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                            if (Native.SetupDiGetDeviceInterfaceDetail(set, ref d, buf, need, out _, IntPtr.Zero))
                                list.Add(Marshal.PtrToStringUni(buf + 4));
                        }
                        finally { Marshal.FreeHGlobal(buf); }
                    }
                }
                finally { Native.SetupDiDestroyDeviceInfoList(set); }
            }
            paths = list;
            pathsAt = DateTime.UtcNow;
            return list;
        }

        static bool? lastExternal;
        static DateTime settleSince = DateTime.MinValue;

        public static BatteryReading Read()
        {
            var r = ReadRaw();
            if (r == null) return null;
            // Right after plugging in or unplugging, the battery's reported rate can lag behind the charger by tens of
            // seconds (still discharging on the charger, still charging off it). Until it agrees, follow the charger.
            if (lastExternal.HasValue && lastExternal.Value != r.ExternalConnected) settleSince = DateTime.UtcNow;
            lastExternal = r.ExternalConnected;
            var settling = (DateTime.UtcNow - settleSince).TotalSeconds < 120;
            var contradicts = r.ExternalConnected ? r.Direction == BatteryReading.Dir.Discharging : r.Direction == BatteryReading.Dir.Charging;
            if (settling && contradicts)
            {
                r.Watts = 0; r.Direction = BatteryReading.Dir.Idle; r.MinutesRemaining = null; r.Estimated = true;
            }
            else if (settling && !contradicts && (DateTime.UtcNow - settleSince).TotalSeconds > 3) settleSince = DateTime.MinValue;
            return r;
        }

        static BatteryReading ReadRaw()
        {
            if (!HasBattery) return null;
            var ps = SystemInformation.PowerStatus;
            var r = new BatteryReading
            {
                ExternalConnected = ps.PowerLineStatus == PowerLineStatus.Online,
                Percent = ps.BatteryLifePercent >= 0 && ps.BatteryLifePercent <= 1 ? (int?)Math.Round(ps.BatteryLifePercent * 100) : null,
            };
            double mw = 0, capNow = 0, capFull = 0, capDesigned = 0;
            bool charging = false, discharging = false, gotRate = false;
            int? cycles = null;
            foreach (var p in DevicePaths())
            {
                using (var h = Native.CreateFile(p, Native.GENERIC_READ | Native.GENERIC_WRITE, Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE,
                                                 IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero))
                {
                    if (h.IsInvalid) continue;
                    var buf = Marshal.AllocHGlobal(64);
                    try
                    {
                        Marshal.WriteInt32(buf, 0);   // timeout 0
                        if (!Native.DeviceIoControl(h, IOCTL_BATTERY_QUERY_TAG, buf, 4, buf + 8, 4, out _, IntPtr.Zero)) continue;
                        var tag = (uint)Marshal.ReadInt32(buf + 8);
                        if (tag == 0) continue;

                        if (!info.TryGetValue(p, out var bi))
                        {
                            // BATTERY_QUERY_INFORMATION { tag, level = BatteryInformation (0), atRate } -> BATTERY_INFORMATION (36 bytes)
                            Marshal.WriteInt32(buf, (int)tag); Marshal.WriteInt32(buf + 4, 0); Marshal.WriteInt32(buf + 8, 0);
                            if (Native.DeviceIoControl(h, IOCTL_BATTERY_QUERY_INFORMATION, buf, 12, buf + 16, 36, out _, IntPtr.Zero))
                            {
                                var o = buf + 16;
                                bi = ((uint)Marshal.ReadInt32(o), (uint)Marshal.ReadInt32(o + 12), (uint)Marshal.ReadInt32(o + 16), (uint)Marshal.ReadInt32(o + 32));
                                info[p] = bi;
                            }
                        }

                        // BATTERY_WAIT_STATUS { tag, timeout, powerState, low, high } -> BATTERY_STATUS { powerState, capacity, voltage, rate }
                        for (var k = 0; k < 5; k++) Marshal.WriteInt32(buf + k * 4, 0);
                        Marshal.WriteInt32(buf, (int)tag);
                        if (!Native.DeviceIoControl(h, IOCTL_BATTERY_QUERY_STATUS, buf, 20, buf + 32, 16, out _, IntPtr.Zero)) continue;
                        var state = (uint)Marshal.ReadInt32(buf + 32);
                        var cap = (uint)Marshal.ReadInt32(buf + 36);
                        var rate = Marshal.ReadInt32(buf + 44);
                        if ((state & CHARGING) != 0) charging = true;
                        if ((state & DISCHARGING) != 0) discharging = true;
                        if ((state & POWER_ON_LINE) != 0) r.ExternalConnected = true;
                        var relative = (bi.caps & CAPACITY_RELATIVE) != 0;
                        if (!relative && (uint)rate != UNKNOWN_RATE) { mw += rate; gotRate = true; }
                        if (!relative && cap != 0xFFFFFFFF) capNow += cap;
                        if (!relative) { capFull += bi.full; capDesigned += bi.designed; }
                        if (bi.cycles > 0) cycles = (int)bi.cycles;
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
            }
            r.Watts = gotRate ? mw / 1000.0 : 0;
            if (charging && r.Watts < 0) r.Watts = -r.Watts;
            if (discharging && r.Watts > 0) r.Watts = -r.Watts;
            r.Direction = charging && Math.Abs(r.Watts) > 0.05 ? BatteryReading.Dir.Charging
                        : discharging && Math.Abs(r.Watts) > 0.05 ? BatteryReading.Dir.Discharging
                        : charging ? BatteryReading.Dir.Charging : discharging ? BatteryReading.Dir.Discharging : BatteryReading.Dir.Idle;
            if (r.Direction != BatteryReading.Dir.Idle && Math.Abs(r.Watts) < 0.05 && !gotRate) r.Direction = BatteryReading.Dir.Idle;
            r.FullyCharged = r.ExternalConnected && !charging && (r.Percent ?? 0) >= 99;
            r.CycleCount = cycles;
            if (capDesigned > 0 && capFull > 0) r.HealthPercent = (int)Math.Round(Math.Min(150, capFull / capDesigned * 100));

            var w = Math.Abs(r.Watts);
            if (r.Direction == BatteryReading.Dir.Discharging)
            {
                if (ps.BatteryLifeRemaining > 0) r.MinutesRemaining = ps.BatteryLifeRemaining / 60;
                else if (w > 0.2 && capNow > 0) r.MinutesRemaining = (int)(capNow / 1000.0 / w * 60);
            }
            else if (r.Direction == BatteryReading.Dir.Charging && w > 0.2 && capFull > capNow)
                r.MinutesRemaining = (int)((capFull - capNow) / 1000.0 / w * 60);
            return r;
        }

        public static string[] Describe(BatteryReading r)
        {
            var pct = r.Percent.HasValue ? " · " + r.Percent + "%" : "";
            var lines = new List<string>();
            switch (r.Direction)
            {
                case BatteryReading.Dir.Discharging:
                    lines.Add("Battery discharging at " + Fmt.Watts(r.Watts) + pct);
                    lines.Add(r.MinutesRemaining.HasValue ? "About " + Fmt.Duration(r.MinutesRemaining.Value) + " until empty" : "Estimating time until empty…");
                    break;
                case BatteryReading.Dir.Charging:
                    lines.Add("Battery charging at " + Fmt.Watts(r.Watts) + pct);
                    lines.Add(r.MinutesRemaining.HasValue ? "About " + Fmt.Duration(r.MinutesRemaining.Value) + " until full" : "Estimating time until full…");
                    break;
                default:
                    lines.Add(r.ExternalConnected
                        ? (r.FullyCharged || (r.Percent ?? 0) >= 100 ? "On power adapter · battery full" + pct : "On power adapter · not charging" + pct)
                        : "Battery idle" + pct);
                    break;
            }
            if (r.Estimated) lines.Add("Just " + (r.ExternalConnected ? "plugged in" : "unplugged") + " — waiting for the battery to report its new rate");
            return lines.ToArray();
        }
    }
}
