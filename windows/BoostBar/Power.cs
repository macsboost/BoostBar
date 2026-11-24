using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BoostBar
{
    /// "Keep Awake": tells Windows the system (and optionally the display) is in use. No admin needed.
    /// Ends when turned off, when the timer runs out, or when BoostBar quits.
    class KeepAwake
    {
        readonly Timer expiry = new Timer();
        public bool IsPreventing { get; private set; }
        public DateTime? Until { get; private set; }
        public event Action Changed;
        bool display;

        public KeepAwake() { expiry.Tick += (s, e) => Allow(); }

        public bool KeepDisplayAwake
        {
            get => display;
            set { display = value; if (IsPreventing) Apply(); }
        }

        public void Prevent(TimeSpan? duration)
        {
            IsPreventing = true;
            Apply();
            expiry.Stop();
            if (duration.HasValue)
            {
                Until = DateTime.Now + duration.Value;
                expiry.Interval = (int)Math.Min(int.MaxValue, Math.Max(1000, duration.Value.TotalMilliseconds));
                expiry.Start();
            }
            else Until = null;
            Changed?.Invoke();
        }

        public void Allow()
        {
            expiry.Stop();
            Until = null;
            IsPreventing = false;
            Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
            Changed?.Invoke();
        }

        void Apply()
        {
            var f = Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED;
            if (display) f |= Native.ES_DISPLAY_REQUIRED;
            Native.SetThreadExecutionState(f);
        }
    }

    /// "Stay awake with the lid closed": sets the active power plan's lid-close action to "Do nothing"
    /// (plugged in and on battery) and puts back what was there when turned off. Like the Mac's
    /// pmset disablesleep, it stays that way after quitting or restarting until you turn it off.
    static class LidSleep
    {
        static Guid ButtonsGroup = new Guid("4f971e89-eebd-4455-a8de-9e59040e7347");
        static Guid LidAction = new Guid("5ca83367-6e45-459f-a27b-476b1d01c936");

        static bool ActiveScheme(out Guid scheme)
        {
            scheme = Guid.Empty;
            if (Native.PowerGetActiveScheme(IntPtr.Zero, out var p) != 0 || p == IntPtr.Zero) return false;
            try { scheme = (Guid)Marshal.PtrToStructure(p, typeof(Guid)); return true; }
            finally { Native.LocalFree(p); }
        }

        static bool Read(out uint ac, out uint dc)
        {
            ac = dc = 1;
            if (!ActiveScheme(out var s)) return false;
            var ok = Native.PowerReadACValueIndex(IntPtr.Zero, ref s, ref ButtonsGroup, ref LidAction, out ac) == 0;
            ok &= Native.PowerReadDCValueIndex(IntPtr.Zero, ref s, ref ButtonsGroup, ref LidAction, out dc) == 0;
            return ok;
        }

        /// Lid action is "Do nothing" both plugged in and on battery.
        public static bool IsDisabled => Read(out var ac, out var dc) && ac == 0 && dc == 0;

        /// Laptops only: desktops have no lid setting worth changing.
        public static bool Available => BatteryMonitor.HasBattery;

        public static bool Set(bool stayAwake)
        {
            if (!Read(out var ac, out var dc)) return false;
            uint newAc, newDc;
            if (stayAwake)
            {
                if (ac != 0 || dc != 0)
                {
                    Prefs.SetInt("lidPrevAC", (int)ac);
                    Prefs.SetInt("lidPrevDC", (int)dc);
                }
                newAc = newDc = 0;
            }
            else
            {
                newAc = (uint)Math.Max(1, Prefs.GetInt("lidPrevAC", 1));
                newDc = (uint)Math.Max(1, Prefs.GetInt("lidPrevDC", 1));
            }
            if (ActiveScheme(out var s) &&
                Native.PowerWriteACValueIndex(IntPtr.Zero, ref s, ref ButtonsGroup, ref LidAction, newAc) == 0 &&
                Native.PowerWriteDCValueIndex(IntPtr.Zero, ref s, ref ButtonsGroup, ref LidAction, newDc) == 0 &&
                Native.PowerSetActiveScheme(IntPtr.Zero, ref s) == 0)
                return true;
            // Some managed PCs only allow this as an administrator: ask once through UAC.
            var cmd = $"/c powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION {newAc} && " +
                      $"powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION {newDc} && powercfg /setactive SCHEME_CURRENT";
            return Shell.RunElevated("cmd.exe", cmd) && IsDisabled == stayAwake;
        }
    }

    static class SleepNow
    {
        public static void Go()
        {
            // Classic sleep; on Modern Standby PCs that call can fail, so fall back to turning the display off,
            // which lets those PCs drop into standby.
            if (!Native.SetSuspendState(false, false, false))
                Native.PostMessage(new IntPtr(0xFFFF), Native.WM_SYSCOMMAND, new IntPtr(Native.SC_MONITORPOWER), new IntPtr(2));
        }
    }
}
