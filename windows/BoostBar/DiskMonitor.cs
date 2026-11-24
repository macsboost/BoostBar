using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace BoostBar
{
    /// Watches every physical drive (internal SSD, USB flash drives, external disks, SD cards)
    /// through the disk driver's performance counters (IOCTL_DISK_PERFORMANCE) — no admin rights needed.
    ///  • fast poll (about half the LED duration) to blink an LED on each read/write
    ///  • 1 Hz sampling of bytes read/written for the hover charts
    class DiskMonitor : IDisposable
    {
        public class Drive
        {
            public int Number;
            public string Key, Name, Kind;
            public bool IsInternal;
            public long Size;
            internal SafeFileHandle Handle;
            internal long LastReadBytes, LastWriteBytes, SecReadBytes, SecWriteBytes;
            internal uint LastReads, LastWrites;
            internal bool HasStats, StatsFailed;
        }

        public class Volume { public string Name, Mount; public long Free, Total; }

        const uint IOCTL_DISK_PERFORMANCE = 0x70020, IOCTL_STORAGE_QUERY_PROPERTY = 0x2D1400,
                   IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x700A0, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x560000;

        public List<Drive> Drives = new List<Drive>();
        public readonly HashSet<string> Lit = new HashSet<string>();
        public readonly Dictionary<string, History> ReadHistory = new Dictionary<string, History>(), WriteHistory = new Dictionary<string, History>();
        readonly Dictionary<string, double> litUntil = new Dictionary<string, double>();
        readonly Stopwatch clock = Stopwatch.StartNew();
        double lastSecond, lastEnum = -100;
        public int DurationMs = 35;
        public event Action DrivesChanged;
        readonly IntPtr buf = Marshal.AllocHGlobal(1024);

        /// Fast tick: returns true when an LED changed state.
        public bool FastTick()
        {
            var now = clock.Elapsed.TotalSeconds;
            if (now - lastEnum > 3) { lastEnum = now; Enumerate(); }
            var changed = false;
            foreach (var d in Drives)
            {
                if (!Stats(d, out var rb, out var wb, out var rc, out var wc)) continue;
                if (d.HasStats && (rc != d.LastReads || wc != d.LastWrites || rb != d.LastReadBytes || wb != d.LastWriteBytes))
                    litUntil[d.Key] = now + DurationMs / 1000.0;
                if (d.HasStats)
                {
                    d.SecReadBytes += Math.Max(0, rb - d.LastReadBytes);
                    d.SecWriteBytes += Math.Max(0, wb - d.LastWriteBytes);
                }
                d.LastReadBytes = rb; d.LastWriteBytes = wb; d.LastReads = rc; d.LastWrites = wc; d.HasStats = true;
            }
            foreach (var d in Drives)
            {
                var on = litUntil.TryGetValue(d.Key, out var u) && u > now;
                if (on != Lit.Contains(d.Key)) { changed = true; if (on) Lit.Add(d.Key); else Lit.Remove(d.Key); }
            }
            if (now - lastSecond >= 1)
            {
                var dt = lastSecond == 0 ? 1 : now - lastSecond;
                lastSecond = now;
                foreach (var d in Drives)
                {
                    if (!ReadHistory.ContainsKey(d.Key)) { ReadHistory[d.Key] = new History(60); WriteHistory[d.Key] = new History(60); }
                    ReadHistory[d.Key].Append(d.SecReadBytes / dt);
                    WriteHistory[d.Key].Append(d.SecWriteBytes / dt);
                    d.SecReadBytes = d.SecWriteBytes = 0;
                }
            }
            return changed;
        }

        bool Stats(Drive d, out long readBytes, out long writeBytes, out uint reads, out uint writes)
        {
            readBytes = writeBytes = 0; reads = writes = 0;
            if (d.StatsFailed || d.Handle == null || d.Handle.IsInvalid) return false;
            if (!Native.DeviceIoControl(d.Handle, IOCTL_DISK_PERFORMANCE, IntPtr.Zero, 0, buf, 128, out _, IntPtr.Zero))
            {
                d.StatsFailed = true;
                return false;
            }
            readBytes = Marshal.ReadInt64(buf, 0);
            writeBytes = Marshal.ReadInt64(buf, 8);
            reads = (uint)Marshal.ReadInt32(buf, 40);
            writes = (uint)Marshal.ReadInt32(buf, 44);
            return true;
        }

        void Enumerate()
        {
            var found = new List<Drive>();
            for (var n = 0; n < 32; n++)
            {
                var existing = Drives.FirstOrDefault(x => x.Number == n);
                var h = existing?.Handle;
                if (h == null || h.IsInvalid || h.IsClosed)
                    h = Native.CreateFile(@"\\.\PhysicalDrive" + n, 0, Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE, IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero);
                if (h.IsInvalid) { h.Dispose(); continue; }
                if (existing != null && Describe(h, out var stillThere) && stillThere == existing.Key) { found.Add(existing); continue; }
                var d = new Drive { Number = n, Handle = h };
                if (!Fill(d)) { h.Dispose(); continue; }
                found.Add(d);
            }
            foreach (var old in Drives.Where(o => !found.Contains(o))) old.Handle?.Dispose();
            var keysChanged = !found.Select(x => x.Key).SequenceEqual(Drives.Select(x => x.Key));
            Drives = found;
            if (keysChanged) DrivesChanged?.Invoke();
        }

        bool Describe(SafeFileHandle h, out string key)
        {
            key = null;
            var d = new Drive { Handle = h };
            if (!Fill(d)) return false;
            key = d.Key;
            return true;
        }

        static string AnsiAt(IntPtr b, int off)
        {
            if (off <= 0 || off >= 1024) return "";
            return (Marshal.PtrToStringAnsi(b + off) ?? "").Trim();
        }

        bool Fill(Drive d)
        {
            // STORAGE_PROPERTY_QUERY { StorageDeviceProperty, PropertyStandardQuery }
            for (var i = 0; i < 12; i++) Marshal.WriteByte(buf, i, 0);
            var outBuf = buf + 16;
            if (!Native.DeviceIoControl(d.Handle, IOCTL_STORAGE_QUERY_PROPERTY, buf, 12, outBuf, 1000, out var got, IntPtr.Zero) || got < 32)
                return false;
            var removable = Marshal.ReadByte(outBuf, 10) != 0;
            var vendor = AnsiAt(outBuf, Marshal.ReadInt32(outBuf, 12));
            var product = AnsiAt(outBuf, Marshal.ReadInt32(outBuf, 16));
            var serial = AnsiAt(outBuf, Marshal.ReadInt32(outBuf, 24));
            var bus = Marshal.ReadInt32(outBuf, 28);
            var name = (vendor + " " + product).Trim();
            if (vendor.Length > 0 && product.StartsWith(vendor, StringComparison.OrdinalIgnoreCase)) name = product;
            d.Name = name.Length > 0 ? name : "Disk " + d.Number;
            d.Key = (product + "|" + serial).Trim('|');
            if (d.Key.Length == 0) d.Key = "PhysicalDrive" + d.Number;
            d.Key = new string(d.Key.Where(ch => char.IsLetterOrDigit(ch) || ch == '-' || ch == '_' || ch == '|').ToArray());
            // BusType: 7 USB, 0xC SD, 0xD MMC, 0x11 NVMe, 0xB SATA, 0xA SAS, 0x8 RAID, 0x13 UFS
            var usb = bus == 7; var sd = bus == 0xC || bus == 0xD;
            d.IsInternal = !(usb || sd || removable);
            d.Kind = usb ? "USB" : sd ? "SD card" : bus == 0x11 ? "NVMe" : bus == 0xB ? "SATA" : bus == 0x13 ? "UFS" : bus == 0xF ? "Virtual" : "Disk";
            if (Native.DeviceIoControl(d.Handle, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, IntPtr.Zero, 0, outBuf, 256, out var g2, IntPtr.Zero) && g2 >= 32)
                d.Size = Marshal.ReadInt64(outBuf, 24);
            return d.Size > 0 || removable;
        }

        /// Mounted volumes that live on this physical drive.
        public List<Volume> Volumes(Drive drive)
        {
            var list = new List<Volume>();
            foreach (var di in DriveInfo.GetDrives())
            {
                try
                {
                    if (!di.IsReady) continue;
                    var letter = di.Name.TrimEnd('\\');
                    using (var h = Native.CreateFile(@"\\.\" + letter, 0, Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE, IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero))
                    {
                        if (h.IsInvalid) continue;
                        var b = Marshal.AllocHGlobal(256);
                        try
                        {
                            if (!Native.DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, IntPtr.Zero, 0, b, 256, out _, IntPtr.Zero)) continue;
                            var count = Marshal.ReadInt32(b, 0);
                            var onIt = false;
                            for (var i = 0; i < Math.Min(count, 8); i++)
                                if (Marshal.ReadInt32(b, 8 + i * 24) == drive.Number) onIt = true;
                            if (!onIt) continue;
                        }
                        finally { Marshal.FreeHGlobal(b); }
                    }
                    var label = string.IsNullOrEmpty(di.VolumeLabel) ? "Local Disk" : di.VolumeLabel;
                    list.Add(new Volume { Name = label, Mount = letter, Free = di.AvailableFreeSpace, Total = di.TotalSize });
                }
                catch { }
            }
            return list;
        }

        public void Dispose()
        {
            foreach (var d in Drives) d.Handle?.Dispose();
            Marshal.FreeHGlobal(buf);
        }
    }
}
