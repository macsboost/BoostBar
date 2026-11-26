using System.Collections.Generic;
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace BoostBar
{
    static class Program
    {
        const string MutexName = @"Local\MacsBoost.BoostBar";
        const string ShowSettingsEvent = @"Local\MacsBoost.BoostBar.ShowSettings";

        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (s, e) => Log(e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => Log(e.ExceptionObject as Exception);

            var snap = Array.IndexOf(args, "--snapshot");
            if (snap >= 0 && snap + 1 < args.Length) return Snapshot(args[snap + 1]);

            var settingsArg = Array.IndexOf(args, "--settings");
            var tab = settingsArg >= 0 && settingsArg + 1 < args.Length ? args[settingsArg + 1] : (settingsArg >= 0 ? "General" : null);

            using (var mutex = new Mutex(true, MutexName, out var first))
            using (var signal = new EventWaitHandle(false, EventResetMode.AutoReset, ShowSettingsEvent))
            {
                if (!first)
                {
                    // already running: ask it to open Settings (used by the screen saver's Settings button)
                    if (tab != null) { Prefs.SetString("pendingSettingsTab", tab); signal.Set(); }
                    return 0;
                }
                var app = new App();
                var ui = SynchronizationContext.Current;
                var waiter = new Thread(() =>
                {
                    while (signal.WaitOne())
                        ui.Post(_ => SettingsForm.ShowShared(Prefs.GetString("pendingSettingsTab", "General")), null);
                }) { IsBackground = true };
                waiter.Start();
                if (tab != null) SettingsForm.ShowShared(tab);
                Application.Run(app);
                GC.KeepAlive(mutex);
            }
            return 0;
        }

        /// Problems go to %LOCALAPPDATA%\BoostBar\BoostBar.log instead of a crash dialog.
        public static void Log(Exception e)
        {
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BoostBar");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "BoostBar.log"), DateTime.Now.ToString("s") + "  " + Updater.CurrentVersion + "\r\n" + e + "\r\n\r\n");
            }
            catch { }
        }

        /// CI layout check: renders the strip (fake readings, several looks) and every window to PNGs, then exits.
        static int Snapshot(string dir)
        {
            Directory.CreateDirectory(dir);
            var rnd = new Random(7);
            double[] Wave(double peak) => Enumerable.Range(0, 30).Select(i => Math.Max(0, peak * (0.35 + 0.65 * Math.Sin(i / 3.0) * Math.Sin(i / 7.0 + 1)) * (0.6 + rnd.NextDouble() * 0.4))).ToArray();
            StripRenderer Make(int variant, bool light)
            {
                var s = new StripRenderer
                {
                    LightBar = light, ShowEyes = true, ShowNetwork = true, ShowBattery = true, ShowCPU = true, ShowDisks = true,
                    EyeSize = 2, Up = Wave(42000), Down = Wave(1300000), UpText = "42 KB/s", DownText = "1.3 MB/s",
                    Battery = new BatteryReading { Watts = -8.4, Direction = BatteryReading.Dir.Discharging, Percent = 76 },
                    CpuCores = Enumerable.Range(0, 12).Select(i => 0.08 + 0.85 * Math.Abs(Math.Sin(i * 1.7))).ToArray(),
                    CpuStyle = 1, CpuBackdrop = -0.6, Cpu = 0.47, LedSize = 1,
                    Leds = new[] { new StripRenderer.Led { Key = "a", Color = Palette.SystemGreen }, new StripRenderer.Led { Key = "b", Color = Color.FromArgb(0, 122, 255) } }.ToList(),
                    PupilOffsets = new[] { new PointF(2, 2.5f), new PointF(-1.5f, 3) },
                };
                s.CpuPeaks = s.CpuCores.Select(v => Math.Min(1, v + 0.12)).ToArray();
                s.LitKeys.Add("a");
                if (variant == 1)
                {
                    s.CpuStyle = 0; s.Bloodshot = true; s.Awake = AwakeState.KeepAwake; s.EyesShowAwake = true;
                    s.Battery = new BatteryReading { Watts = 42, Direction = BatteryReading.Dir.Charging, Percent = 51, ExternalConnected = true };
                    s.UpColor = Palette.Resolve("Boost Green", Color.White); s.DownColor = Palette.Resolve("Lime", Color.White);
                }
                if (variant == 2)
                {
                    s.VerticalLabels = true; s.Pirate = true; s.CpuBackdrop = 0; s.EyesClosed = false; s.NetUnit = Fmt.NetUnit.Mega;
                    s.NetRows = new[]
                    {
                        new StripRenderer.NetRow { Id = "1", Kind = NetLink.LinkKind.Ethernet, Up = Wave(900000), Down = Wave(23000000), UpText = "0.90 MB/s", DownText = "23.4 MB/s" },
                        new StripRenderer.NetRow { Id = "2", Kind = NetLink.LinkKind.WiFi, Up = Wave(3000), Down = Wave(80000), UpText = "0.00 MB/s", DownText = "0.08 MB/s" },
                    }.ToList();
                    s.Battery = new BatteryReading { Direction = BatteryReading.Dir.Idle, Percent = 100, ExternalConnected = true, FullyCharged = true };
                }
                return s;
            }
            foreach (var (name, h, zoom) in new[] { ("win11_100", 48, 1.4f), ("win10_100", 40, 1.4f), ("win11_150", 72, 2.1f) })
                foreach (var light in new[] { false, true })
                    for (var v = 0; v < 3; v++)
                    {
                        var s = Make(v, light);
                        var w = (int)Math.Ceiling(s.Layout() * zoom);
                        using (var strip = StripWindow.RenderBitmap(s, zoom, w, h))
                        using (var bg = new Bitmap(w + 40, h))
                        using (var g = Graphics.FromImage(bg))
                        {
                            g.Clear(light ? Color.FromArgb(238, 238, 238) : Color.FromArgb(32, 32, 32));
                            g.DrawImage(strip, 20, 0, w, h);
                            bg.Save(Path.Combine(dir, $"strip_{name}_{(light ? "light" : "dark")}_{v}.png"), ImageFormat.Png);
                        }
                    }
            // every emotion, large eyes, on a dark and a light taskbar
            for (var lash = 0; lash <= 2; lash++)
            foreach (var light in new[] { false, true })
            {
                var faces = new List<(string, EyeFace)> { ("plain", new EyeFace()) };
                foreach (var e in Emotions.All)
                {
                    var f = EyeFace.Pose(e, 0.7f);
                    faces.Add((Emotions.Key(e), f));
                    if (e == Emotion.Hearts) { var d = f.Clone(); d.Symbol = 2; faces.Add(("dollar", d)); }
                }
                const float zoom = 3f; const int cell = 48 * 3, hh = 66;
                using (var bg = new Bitmap(cell * faces.Count, hh))
                using (var g = Graphics.FromImage(bg))
                {
                    g.Clear(light ? Color.FromArgb(238, 238, 238) : Color.FromArgb(32, 32, 32));
                    for (var k = 0; k < faces.Count; k++)
                    {
                        var s = new StripRenderer { LightBar = light, ShowEyes = true, ShowNetwork = false, ShowBattery = false, ShowCPU = false, ShowDisks = false, EyeSize = 2, Lashes = lash };
                        s.Face = faces[k].Item2;
                        var down = faces[k].Item1 == "sad" || faces[k].Item1 == "sleepy";
                        s.PupilOffsets = new[] { new PointF(1, down ? 2.5f : 0), new PointF(1, down ? 2.5f : 0) };
                        var w = (int)Math.Ceiling(s.Layout() * zoom);
                        using (var strip = StripWindow.RenderBitmap(s, zoom, w, hh)) g.DrawImage(strip, k * cell + (cell - w) / 2, 0, w, hh);
                    }
                    bg.Save(Path.Combine(dir, $"eyes_emotions{(lash == 0 ? "" : lash == 1 ? "_natural" : "_fake")}_{(light ? "light" : "dark")}.png"), ImageFormat.Png);
                }
            }
            try { using (var f = new SettingsForm(true)) f.Snapshot(dir); } catch (Exception e) { File.WriteAllText(Path.Combine(dir, "settings_error.txt"), e.ToString()); }
            try
            {
                using (var a = new AboutForm())
                {
                    a.Show(); Application.DoEvents();
                    using (var bmp = new Bitmap(a.Width, a.Height)) { a.DrawToBitmap(bmp, new Rectangle(0, 0, a.Width, a.Height)); bmp.Save(Path.Combine(dir, "about.png")); }
                }
            }
            catch (Exception e) { File.WriteAllText(Path.Combine(dir, "about_error.txt"), e.ToString()); }
            try
            {
                var hp = new HoverPanel();
                var c = new HoverContent
                {
                    Title = "Network", Lines = new[] { "Network: MacsBoost-5G", "Upload 42 KB/s  ·  Download 1.3 MB/s", "Last 5 min: 12 MB sent · 380 MB received" }, Timespan = "last 5 min",
                    Top = new HoverContent.Series { Label = "Upload", Values = Enumerable.Range(0, 300).Select(i => 40000 + 30000 * Math.Sin(i / 9.0)).ToArray(), Color = Color.White, Format = x => Fmt.Rate(x, false) },
                    Bottom = new HoverContent.Series { Label = "Download", Values = Enumerable.Range(0, 300).Select(i => 1e6 + 9e5 * Math.Sin(i / 13.0)).ToArray(), Color = Color.FromArgb(0, 122, 255), Format = x => Fmt.Rate(x, false) },
                };
                hp.ShowFor(c, new Rectangle(600, 900, 60, 40), true, 1);
                Application.DoEvents();
                using (var bmp = new Bitmap(hp.Width, hp.Height)) { hp.DrawToBitmap(bmp, new Rectangle(0, 0, hp.Width, hp.Height)); bmp.Save(Path.Combine(dir, "hover.png")); }
                hp.Close();
            }
            catch (Exception e) { File.WriteAllText(Path.Combine(dir, "hover_error.txt"), e.ToString()); }
            return 0;
        }
    }
}
