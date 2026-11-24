using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace BoostBar
{
    /// Whole-machine CPU load from the kernel's per-processor time counters (no permission needed).
    class CpuMonitor
    {
        public double[] Cores = new double[0];
        public double Total, User, Sys;
        public readonly History TotalHistory = new History(300), UserHistory = new History(300), SystemHistory = new History(300);

        Native.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION[] last;
        readonly Stopwatch clock = Stopwatch.StartNew();
        double sinceRecord, accTotal, accUser, accSystem, accN, lastTime;
        static readonly int Size = Marshal.SizeOf(typeof(Native.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION));

        static Native.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION[] Read()
        {
            var n = Environment.ProcessorCount;
            var len = Size * n;
            var buf = Marshal.AllocHGlobal(len);
            try
            {
                if (Native.NtQuerySystemInformation(8, buf, len, out var ret) != 0) return null;
                var count = Math.Max(1, ret / Size);
                var arr = new Native.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION[count];
                for (var i = 0; i < count; i++)
                    arr[i] = (Native.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION)Marshal.PtrToStructure(buf + i * Size, typeof(Native.SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION));
                return arr;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        /// Call a few times a second; the 5-minute history still gets one (averaged) point per second.
        public void Sample()
        {
            var cur = Read();
            if (cur == null) return;
            var prev = last;
            last = cur;
            if (prev == null || prev.Length != cur.Length) return;
            double busyAll = 0, allAll = 0, userAll = 0, sysAll = 0;
            var cores = new double[cur.Length];
            for (var i = 0; i < cur.Length; i++)
            {
                double idle = cur[i].IdleTime - prev[i].IdleTime;
                double kernel = cur[i].KernelTime - prev[i].KernelTime;   // includes idle
                double user = cur[i].UserTime - prev[i].UserTime;
                var all = kernel + user;
                var sys = Math.Max(0, kernel - idle);
                cores[i] = all > 0 ? Math.Min(1, Math.Max(0, (all - idle) / all)) : 0;
                busyAll += Math.Max(0, all - idle); allAll += all; userAll += user; sysAll += sys;
            }
            Cores = cores;
            Total = allAll > 0 ? busyAll / allAll : 0;
            User = allAll > 0 ? userAll / allAll : 0;
            Sys = allAll > 0 ? sysAll / allAll : 0;
            var now = clock.Elapsed.TotalSeconds;
            sinceRecord += now - lastTime; lastTime = now;
            accTotal += Total; accUser += User; accSystem += Sys; accN += 1;
            if (sinceRecord >= 1)
            {
                TotalHistory.Append(accTotal / accN); UserHistory.Append(accUser / accN); SystemHistory.Append(accSystem / accN);
                sinceRecord = 0; accTotal = accUser = accSystem = accN = 0;
            }
        }
    }
}
