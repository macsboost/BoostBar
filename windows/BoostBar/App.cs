using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;

namespace BoostBar
{
    /// The running app: monitors, the taskbar strip, the tray icon and its menu.
    class App : ApplicationContext
    {
        public static App Shared;
        public static readonly (string Label, int? Minutes)[] AwakeDurations =
            { ("Indefinitely", null), ("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480) };

        public readonly NetworkMonitor Net = new NetworkMonitor();
        public readonly CpuMonitor Cpu = new CpuMonitor();
        public readonly DiskMonitor Disk = new DiskMonitor();
        public readonly KeepAwake Sleep = new KeepAwake();
        public readonly ScrollReverser Scroll = new ScrollReverser();
        public readonly Updater Updater;
        readonly HotCorners corners = new HotCorners();
        readonly EyesAnimator eyes = new EyesAnimator();
        readonly StripRenderer strip = new StripRenderer();
        readonly History batteryHistory = new History(600);
        public BatteryReading Battery;
        public bool LidDisabled;

        StripWindow window;
        readonly NotifyIcon tray;
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly HoverPanel hover = new HoverPanel();
        readonly Timer secondTimer = new Timer { Interval = 1000 }, cpuTimer = new Timer(), diskTimer = new Timer(), eyesTimer = new Timer { Interval = FrameMs },
                       renderTimer = new Timer(), hoverTimer = new Timer();
        readonly SynchronizationContext ui;
        bool dirty = true, menuOpen;
        /// One frame at up to 60 Hz. WinForms timers tick on the 15.6 ms system clock, so 15 ms fires every tick (~64 Hz)
        /// while 16 ms would round up to every other tick (~32 Hz). Asking for 1 ms timer resolution would cost battery.
        const int FrameMs = 15;
        double lastRender = -1;
        int eyesIdleFrames;

        /// Asks for a redraw: drawn on the next frame, no sooner than one frame after the last, and never while
        /// nothing has changed (the render timer only runs while a redraw is pending).
        void MarkDirty()
        {
            dirty = true;
            if (renderTimer.Enabled) return;
            var since = (clock.Elapsed.TotalSeconds - lastRender) * 1000;
            renderTimer.Interval = Math.Max(1, FrameMs - (int)since);
            renderTimer.Start();
        }
        HoverTarget hoverTarget, pendingHover;

        // CPU meter animation
        readonly Stopwatch clock = Stopwatch.StartNew();
        double cpuSince = 1, cpuLastFrame;
        double cpuShown;
        double[] cpuCoresShown = new double[0], cpuPeaks = new double[0], cpuPeakAt = new double[0];

        // click / drag on the strip
        Point? downAt; Segment? downSeg; bool dragging; Point dragLast;

        public App()
        {
            Shared = this;
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
            Updater = new Updater();
            Prefs.RegisterDefaults();
            Prefs.Changed += () => ui.Post(_ => ApplySettings(), null);

            tray = new NotifyIcon { Text = "BoostBar", Icon = AppIcon(16), Visible = true, ContextMenuStrip = menu };
            tray.MouseUp += (s, e) => { if (e.Button == MouseButtons.Left) ShowMenu(Cursor.Position); };
            menu.Opening += (s, e) => { BuildMenu(); menuOpen = true; HideHover(); };
            menu.Closed += (s, e) => menuOpen = false;
            menu.ShowItemToolTips = true;

            window = new StripWindow(Prefs.Placement == 1);
            window.MouseMoved += OnStripMove;
            window.MouseLeft += () => { if (!dragging) HoverChanged(null); };
            window.LeftDown += OnStripDown;
            window.LeftUp += OnStripUp;
            window.RightUp += p => ShowMenu(Cursor.Position);
            window.LayoutChanged += () => { MarkDirty(); };
            window.Start();

            Sleep.KeepDisplayAwake = Prefs.KeepDisplayAwake;
            Sleep.Changed += () => { ApplySettings(); SettingsForm.RefreshOpen(); };
            corners.OnCorner += HotCorner;
            Disk.DrivesChanged += () => ui.Post(_ => { ApplySettings(); SettingsForm.RefreshOpen(); }, null);

            secondTimer.Tick += (s, e) => Tick();
            cpuTimer.Tick += (s, e) => CpuStep();
            diskTimer.Tick += (s, e) => { if (Disk.FastTick()) { strip.LitKeys = new HashSet<string>(Disk.Lit); MarkDirty(); } };
            eyesTimer.Tick += (s, e) => EyesStep();
            renderTimer.Tick += (s, e) => { renderTimer.Stop(); if (dirty) Render(); };
            hoverTimer.Tick += (s, e) => { hoverTimer.Stop(); if (pendingHover == null) HideHover(); else ShowHover(pendingHover); };

            LidDisabled = LidSleep.Available && LidSleep.IsDisabled;
            if (Prefs.ReverseScroll) Scroll.Start();
            Scroll.ReverseHorizontal = Prefs.ReverseHorizontal;

            Net.Sample();
            Cpu.Sample();
            ScreenSavers.MigrateRenamed();
            ApplySettings();
            secondTimer.Start();
            diskTimer.Start();
            MarkDirty();

            AboutForm.ShowIfFirstLaunch();
            InstallPing.SendIfNeeded();
            if (Prefs.CheckOnLaunch)
            {
                var t = new Timer { Interval = 3000 };
                t.Tick += (s, e) => { t.Stop(); t.Dispose(); Updater.Check(false); };
                t.Start();
            }
            Application.ApplicationExit += (s, e) => Shutdown();
        }

        public static Icon AppIcon(int size)
        {
            using (var st = typeof(App).Assembly.GetManifestResourceStream("BoostBar.ico"))
                return st != null ? new Icon(st, size, size) : SystemIcons.Application;
        }

        void Shutdown()
        {
            tray.Visible = false;
            Scroll.Stop();
            if (Sleep.IsPreventing) Sleep.Allow();
            window?.Dispose();
            Disk.Dispose();
        }

        // ---------------- settings → strip ----------------

        public void ApplySettings()
        {
            strip.Order = dragging ? strip.Order : Prefs.SegmentOrder;
            strip.ShowNetwork = Prefs.ShowNetwork;
            strip.ShowBattery = Prefs.ShowBattery;
            strip.ShowDisks = Prefs.ShowDisks;
            strip.ShowEyes = Prefs.ShowEyes;
            strip.ShowCPU = Prefs.ShowCPU;
            strip.NetUnit = Prefs.NetUnit;
            strip.NetBits = Prefs.UseBits;
            strip.NetDisplay = Prefs.NetDisplay;
            strip.CpuStyle = Prefs.CpuStyle;
            strip.CpuBackdrop = Prefs.CpuBackdrop;
            strip.EyeSize = Prefs.EyeSize;
            strip.SingleEye = Prefs.SingleEye;
            strip.Bloodshot = Prefs.Bloodshot || (Prefs.BloodshotAwake && (Sleep.IsPreventing || LidDisabled));
            strip.EyesShowAwake = Prefs.BloodshotAwake && !Prefs.Bloodshot;
            strip.VerticalLabels = Prefs.VerticalLabels;
            strip.Pirate = Prefs.Pirate; strip.Lashes = Prefs.Lashes;
            strip.LedSize = Prefs.LedSize;
            strip.UpColor = Prefs.UpColor;
            strip.DownColor = Prefs.DownColor;
            strip.Awake = LidDisabled ? AwakeState.LidAwake : Sleep.IsPreventing ? AwakeState.KeepAwake : AwakeState.Normal;
            Disk.DurationMs = Prefs.LedDurationMs;
            diskTimer.Interval = Math.Max(10, Math.Min(250, Prefs.LedDurationMs / 2));
            strip.Leds = Disk.Drives.Where(d => Prefs.DiskEnabled(d.Key))
                .Select(d => new StripRenderer.Led { Key = d.Key, Color = DiskColor(d) }).ToList();

            eyes.Googly = Prefs.Googly; eyes.Blink = Prefs.EyeBlink; eyes.AllowCrossEye = Prefs.AllowCrossEye; eyes.Lazy = Prefs.LazyEyes;
            eyes.Emotions = Prefs.EmotionsOn;
            eyesTimer.Enabled = Prefs.ShowEyes;
            SetCpuMeterRunning(Prefs.ShowCPU);
            corners.Watch(new[] { Prefs.CornerAwake, Prefs.CornerSleep, Prefs.CornerSaver });
            Scroll.ReverseHorizontal = Prefs.ReverseHorizontal;
            if (Prefs.ReverseScroll && !Scroll.IsRunning) Scroll.Start();
            if (!Prefs.ReverseScroll && Scroll.IsRunning) Scroll.Stop();
            window.SetFloating(Prefs.Placement == 1);
            RefreshContent();
        }

        public Color DiskColor(DiskMonitor.Drive d) => Palette.Resolve(Prefs.DiskColorName(d.Key, d.IsInternal), Palette.SystemGreen);

        void RefreshContent()
        {
            var bits = Prefs.UseBits; var unit = Prefs.NetUnit;
            Battery = BatteryMonitor.HasBattery ? BatteryMonitor.Read() : null;
            strip.Battery = Battery;
            strip.Up = Net.Up.Values; strip.Down = Net.Down.Values;
            strip.UpText = Fmt.Rate(Net.CurrentUp, bits, unit);
            strip.DownText = Fmt.Rate(Net.CurrentDown, bits, unit);
            var links = Prefs.NetSplit ? Net.ActiveLinks : new List<NetLink>();
            strip.NetRows = links.Count >= 2
                ? links.Select(l => new StripRenderer.NetRow { Id = l.Id, Kind = l.Kind, Up = l.Up.Values, Down = l.Down.Values,
                    UpText = Fmt.Rate(l.CurrentUp, bits, unit), DownText = Fmt.Rate(l.CurrentDown, bits, unit) }).ToList()
                : new List<StripRenderer.NetRow>();
            strip.LitKeys = new HashSet<string>(Disk.Lit);
            strip.LightBar = window.Embedded ? Theme.TaskbarIsLight : false;
            MarkDirty();
        }

        void Tick()
        {
            Net.Sample();
            if (BatteryMonitor.HasBattery) { var b = BatteryMonitor.Read(); if (b != null) batteryHistory.Append(b.Watts); }
            FeedEmotions();
            if (LidSleep.Available && clock.Elapsed.TotalSeconds % 10 < 1.05) LidDisabled = LidSleep.IsDisabled;
            strip.Awake = LidDisabled ? AwakeState.LidAwake : Sleep.IsPreventing ? AwakeState.KeepAwake : AwakeState.Normal;
            RefreshContent();
            if (hover.Visible && hoverTarget != null) { var c = HoverContentFor(hoverTarget); if (c != null) hover.UpdateContent(c); }
        }

        void Render()
        {
            dirty = false;
            lastRender = clock.Elapsed.TotalSeconds;
            if (dragging) strip.Dragging = downSeg; else strip.Dragging = null;
            var w = strip.Layout();
            window.Render(strip, w);
        }

        // ---------------- CPU meter: fast clock with automatic damping ----------------

        void SetCpuMeterRunning(bool on)
        {
            if (!on) { cpuTimer.Stop(); return; }
            // animate at 20 fps, or as fast as readings come in, up to 60 fps (see FrameMs)
            var hz = Math.Min(60, Math.Max(20, Prefs.CpuRate));
            var interval = hz >= 55 ? FrameMs : (int)Math.Round(1000 / hz);
            if (cpuTimer.Enabled && cpuTimer.Interval == interval) return;
            cpuTimer.Interval = Math.Max(FrameMs, interval);
            cpuTimer.Start();
        }

        void CpuStep()
        {
            var now = clock.Elapsed.TotalSeconds;
            var dt = Math.Min(0.1, Math.Max(0.001, now - cpuLastFrame));
            var rate = Prefs.CpuRate;
            cpuLastFrame = now;
            cpuSince += dt;
            if (cpuSince >= 1 / rate - 0.004) { cpuSince = 0; Cpu.Sample(); }
            var k = 1 - Math.Exp(-dt / Math.Max(0.06, 0.65 / rate));
            var moved = Math.Abs(Cpu.Total - cpuShown) > 0.002;
            cpuShown += (Cpu.Total - cpuShown) * k;
            if (cpuCoresShown.Length != Cpu.Cores.Length) { cpuCoresShown = (double[])Cpu.Cores.Clone(); moved = true; }
            for (var i = 0; i < cpuCoresShown.Length; i++)
            {
                if (Math.Abs(Cpu.Cores[i] - cpuCoresShown[i]) > 0.004) moved = true;
                cpuCoresShown[i] += (Cpu.Cores[i] - cpuCoresShown[i]) * k;
            }
            var hold = Prefs.CpuStyle == 1 ? Prefs.CpuPeakHold : 0;
            if (hold > 0)
            {
                if (cpuPeaks.Length != cpuCoresShown.Length) { cpuPeaks = (double[])cpuCoresShown.Clone(); cpuPeakAt = Enumerable.Repeat(now, cpuCoresShown.Length).ToArray(); }
                for (var i = 0; i < cpuPeaks.Length; i++)
                {
                    if (cpuCoresShown[i] >= cpuPeaks[i]) { cpuPeaks[i] = cpuCoresShown[i]; cpuPeakAt[i] = now; }
                    else if (now - cpuPeakAt[i] > hold) { cpuPeaks[i] = Math.Max(cpuCoresShown[i], cpuPeaks[i] - 0.9 * dt); moved = true; }
                }
            }
            else if (cpuPeaks.Length > 0) { cpuPeaks = new double[0]; moved = true; }
            strip.CpuPeaks = (double[])cpuPeaks.Clone();
            if (!moved) return;
            strip.Cpu = cpuShown;
            strip.CpuCores = (double[])cpuCoresShown.Clone();
            MarkDirty();
        }

        // ---------------- eyes ----------------

        // What the eyes' emotions react to, gathered once a second.
        bool? wasOnCharger; int? knownDrives; int fastDownloadSeconds;

        void FeedEmotions()
        {
            if (!Prefs.ShowEyes) return;
            if (!Prefs.ShowCPU) Cpu.Sample();                  // the meter's own clock isn't running
            eyes.CpuLoad = Cpu.Total;
            eyes.BatteryPercent = Battery?.Percent;
            var charger = Battery?.ExternalConnected ?? true;
            eyes.OnCharger = charger;
            if (wasOnCharger == false && charger) eyes.Trigger(Emotion.Happy, 4);          // charger plugged in
            wasOnCharger = charger;
            try { eyes.NetDown = !System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable(); } catch { eyes.NetDown = false; }
            // a big download finishing: fast for a while, then quiet
            if (Net.CurrentDown > 1_000_000) fastDownloadSeconds++;
            else
            {
                if (Net.CurrentDown < 100_000 && fastDownloadSeconds >= 10) eyes.Trigger(Emotion.Happy, 4);
                if (Net.CurrentDown < 100_000) fastDownloadSeconds = 0;
            }
            var n = Disk.Drives.Count;                       // a drive plugged in
            if (knownDrives.HasValue && n > knownDrives.Value) eyes.Trigger(Emotion.Startled, 0.9);
            knownDrives = n;
        }

        /// Settings ▸ Eyes ▸ Emotions: hovering a checkbox previews that emotion until the pointer leaves it.
        public void PreviewEmotion(Emotion e, bool on)
        {
            if (on) { eyes.Trigger(e, 3600, force: true); eyesTimer.Interval = FrameMs; } else eyes.EndPreview(e);
        }

        /// A tip button in About was clicked: hearts (and dollar signs).
        public void Tipped() => eyes.Trigger(Emotion.Hearts, 5);

        void EyesStep()
        {
            if (strip.EyeRects.Count == 0) return;
            var b = window.ScreenBounds;
            var z = window.Zoom;
            var yOff = (window.HeightPx / z - StripRenderer.BandHeight) / 2;
            var centers = strip.EyeRects.Select(r => new PointF(b.X + (r.X + r.Width / 2) * z, b.Y + (r.Y + r.Height / 2 + yOff) * z)).ToArray();
            eyes.Zoom = z;
            Native.GetCursorPos(out var p);
            if (eyes.Step(strip, centers, new PointF(p.X, p.Y)))
            {
                MarkDirty();
                eyesIdleFrames = 0;
                if (eyesTimer.Interval != FrameMs) eyesTimer.Interval = FrameMs;
            }
            else if (++eyesIdleFrames > 60 && eyesTimer.Interval != 100)
                eyesTimer.Interval = 100;   // still for a second: check 10×/s (enough to catch a blink or the pointer moving)
        }

        // ---------------- mouse on the strip ----------------

        PointF ToUnits(Point px)
        {
            var z = window.Zoom;
            return new PointF(px.X / z, px.Y / z - (window.HeightPx / z - StripRenderer.BandHeight) / 2);
        }

        void OnStripMove(Point px)
        {
            if (downAt.HasValue)
            {
                if (!window.Embedded)
                {
                    // floating: drag the whole bar
                    Native.GetCursorPos(out var sp);
                    if (dragging || Math.Abs(sp.X - dragLast.X) + Math.Abs(sp.Y - dragLast.Y) > 3)
                    {
                        dragging = true; HideHover();
                        window.MoveFloatingBy(sp.X - dragLast.X, sp.Y - dragLast.Y);
                        dragLast = new Point(sp.X, sp.Y);
                        MarkDirty();
                    }
                    return;
                }
                if (downSeg.HasValue && (dragging || Math.Abs(px.X - downAt.Value.X) > 3 * window.Zoom))
                {
                    dragging = true; HideHover();
                    var p = ToUnits(px);
                    var visible = strip.Order.Where(s => !strip.RectOf(s).IsEmpty).ToList();
                    var others = visible.Where(s => s != downSeg.Value).ToList();
                    var index = others.Count(s => { var r = strip.RectOf(s); return r.X + r.Width / 2 < p.X; });
                    others.Insert(index, downSeg.Value);
                    var newOrder = others.Concat(strip.Order.Where(s => !visible.Contains(s))).ToArray();
                    if (!newOrder.SequenceEqual(strip.Order)) strip.Order = newOrder;
                    MarkDirty();
                    return;
                }
                return;
            }
            HoverChanged(strip.TargetAt(ToUnits(px)));
        }

        void OnStripDown(Point px)
        {
            downAt = px;
            downSeg = strip.SegmentAt(ToUnits(px));
            Native.GetCursorPos(out var sp);
            dragLast = new Point(sp.X, sp.Y);
            dragging = false;
            window.Capture(true);
        }

        void OnStripUp(Point px)
        {
            window.Capture(false);
            var wasDragging = dragging;
            var seg = downSeg;
            downAt = null; downSeg = null; dragging = false;
            if (wasDragging)
            {
                if (window.Embedded) Prefs.SegmentOrder = strip.Order; else window.SaveFloatingPosition();
                MarkDirty();
                return;
            }
            if (seg == Segment.Eyes) { HideHover(); AboutForm.ShowShared(); }
            else ShowMenu(Cursor.Position);
        }

        // ---------------- hover ----------------

        void HoverChanged(HoverTarget t)
        {
            if (Equals(t, hoverTarget) && (t != null || pendingHover == null)) return;
            pendingHover = t;
            hoverTimer.Stop();
            if (t == null) { hoverTimer.Interval = 200; hoverTimer.Start(); return; }
            if (hover.Visible) ShowHover(t);
            else { hoverTimer.Interval = 350; hoverTimer.Start(); }
        }

        void ShowHover(HoverTarget t)
        {
            if (menuOpen || dragging) return;
            var c = HoverContentFor(t);
            if (c == null) { HideHover(); return; }
            hoverTarget = t;
            var r = strip.RectFor(t);
            var z = window.Zoom; var b = window.ScreenBounds;
            var yOff = (window.HeightPx / z - StripRenderer.BandHeight) / 2;
            var anchor = new Rectangle((int)(b.X + r.X * z), b.Y, Math.Max(1, (int)(r.Width * z)), b.Height);
            if (!window.Embedded) anchor = new Rectangle(anchor.X, (int)(b.Y + (r.Y + yOff) * z), anchor.Width, (int)(r.Height * z));
            var above = !window.TaskbarOnTop && (window.Embedded || b.Y > Screen.FromRectangle(b).Bounds.Height / 2);
            hover.ShowFor(c, anchor, above, z / 1.4f);
        }

        void HideHover()
        {
            hoverTimer.Stop();
            hoverTarget = null; pendingHover = null;
            if (hover.Visible) hover.Hide();
        }

        HoverContent HoverContentFor(HoverTarget t)
        {
            var bits = Prefs.UseBits;
            Func<double, string> rate = v => Fmt.Rate(v, bits);
            switch (t.Kind)
            {
                case HoverTarget.K.Network:
                {
                    var l = Net.Link(t.Id);
                    if (l != null)
                    {
                        var lines = new List<string>
                        {
                            "Upload " + rate(l.CurrentUp) + "  ·  Download " + rate(l.CurrentDown),
                            "Last 5 min: " + Fmt.Bytes(l.LongUp.Sum) + " sent · " + Fmt.Bytes(l.LongDown.Sum) + " received",
                            "All connections: ▲ " + rate(Net.CurrentUp) + "  ▼ " + rate(Net.CurrentDown),
                        };
                        if (l.Kind == NetLink.LinkKind.WiFi) { var w = NetworkMonitor.WiFiLine(); if (w != null) lines.Insert(0, w); }
                        return new HoverContent
                        {
                            Title = l.Short + " — " + l.Name, Lines = lines.ToArray(), Timespan = "last 5 min",
                            Top = new HoverContent.Series { Label = "Upload", Values = l.LongUp.Values, Color = Prefs.UpColor, Format = rate },
                            Bottom = new HoverContent.Series { Label = "Download", Values = l.LongDown.Values, Color = Prefs.DownColor, Format = rate },
                        };
                    }
                    var ls = new List<string>
                    {
                        "Upload " + rate(Net.CurrentUp) + "  ·  Download " + rate(Net.CurrentDown),
                        "Last 5 min: " + Fmt.Bytes(Net.LongUp.Sum) + " sent · " + Fmt.Bytes(Net.LongDown.Sum) + " received",
                    };
                    var active = Net.ActiveLinks;
                    if (active.Any(a => a.Kind == NetLink.LinkKind.WiFi)) { var w = NetworkMonitor.WiFiLine(); if (w != null) ls.Insert(0, active.Count > 1 ? w.Replace("Network: ", "Wi‑Fi network: ") : w); }
                    if (active.Count > 1) foreach (var a in active) ls.Add(a.Short + ": ▲ " + rate(a.CurrentUp) + "  ▼ " + rate(a.CurrentDown));
                    if (LidDisabled) ls.Add("Staying awake with the lid closed");
                    else if (Sleep.IsPreventing) ls.Add("Keeping PC awake");
                    return new HoverContent
                    {
                        Title = "Network", Lines = ls.ToArray(), Timespan = "last 5 min",
                        Top = new HoverContent.Series { Label = "Upload", Values = Net.LongUp.Values, Color = Prefs.UpColor, Format = rate },
                        Bottom = new HoverContent.Series { Label = "Download", Values = Net.LongDown.Values, Color = Prefs.DownColor, Format = rate },
                    };
                }
                case HoverTarget.K.Battery:
                {
                    var b = Battery ?? BatteryMonitor.Read();
                    if (b == null) return null;
                    var lines = BatteryMonitor.Describe(b).ToList();
                    var health = new List<string>();
                    if (b.CycleCount.HasValue) health.Add("Cycle count: " + b.CycleCount);
                    if (b.HealthPercent.HasValue) health.Add("Health: " + b.HealthPercent + "% of original capacity");
                    if (health.Count > 0) lines.Add(string.Join("  ·  ", health));
                    var vals = batteryHistory.Values;
                    Func<double, string> watts = Fmt.Watts;
                    return new HoverContent
                    {
                        Title = "Battery" + (b.Percent.HasValue ? " — " + b.Percent + "%" : ""), Lines = lines.ToArray(), Timespan = "last 10 min",
                        Top = new HoverContent.Series { Label = "Charging", Values = vals.Select(v => Math.Max(v, 0)).ToArray(), Color = Palette.SystemGreen, Format = watts },
                        Bottom = new HoverContent.Series { Label = "Discharging", Values = vals.Select(v => Math.Max(-v, 0)).ToArray(), Color = Palette.SystemOrange, Format = watts },
                    };
                }
                case HoverTarget.K.Cpu:
                {
                    Func<double, string> pct = Fmt.Pct;
                    var lines = new List<string> { "User " + pct(Cpu.User) + "  ·  System " + pct(Cpu.Sys) + "  ·  " + Cpu.Cores.Length + " logical processors" };
                    if (Cpu.Cores.Length > 0)
                    {
                        var i = Array.IndexOf(Cpu.Cores, Cpu.Cores.Max());
                        lines.Add("Busiest: #" + (i + 1) + " at " + pct(Cpu.Cores[i]));
                    }
                    return new HoverContent
                    {
                        Title = "CPU — " + pct(Cpu.Total), Lines = lines.ToArray(), Timespan = "last 5 min",
                        Top = new HoverContent.Series { Label = "User", Values = Cpu.UserHistory.Values, Color = Palette.SystemGreen, Format = pct },
                        Bottom = new HoverContent.Series { Label = "System", Values = Cpu.SystemHistory.Values, Color = Palette.SystemOrange, Format = pct },
                    };
                }
                default:
                {
                    var d = Disk.Drives.FirstOrDefault(x => x.Key == t.Id);
                    if (d == null) return null;
                    Disk.ReadHistory.TryGetValue(d.Key, out var r);
                    Disk.WriteHistory.TryGetValue(d.Key, out var w);
                    r = r ?? new History(60); w = w ?? new History(60);
                    Func<double, string> dr = v => Fmt.Rate(v, false);
                    var lines = new List<string> { "Disk " + d.Number + "  ·  " + d.Kind + "  ·  " + Fmt.Bytes(d.Size) };
                    var vols = Disk.Volumes(d);
                    if (vols.Count == 0) lines.Add("No mounted volumes");
                    foreach (var v in vols.Take(4)) lines.Add(v.Name + " (" + v.Mount + ") — " + Fmt.Bytes(v.Free) + " free of " + Fmt.Bytes(v.Total));
                    lines.Add("Last second: read " + dr(r.Last) + " · write " + dr(w.Last));
                    return new HoverContent
                    {
                        Title = d.Name, Lines = lines.ToArray(), Timespan = "last 60 s",
                        Top = new HoverContent.Series { Label = "Read", Values = r.Values, Color = DiskColor(d), Format = dr },
                        Bottom = new HoverContent.Series { Label = "Write", Values = w.Values, Color = Palette.SystemPink, Format = dr },
                    };
                }
            }
        }

        // ---------------- menu ----------------

        void ShowMenu(Point screen)
        {
            HideHover();
            // the menu needs our app in front to close properly when you click elsewhere
            var f = Form.ActiveForm;
            menu.Show(screen);
        }

        ToolStripMenuItem Item(string text, Action act, bool check = false, bool enabled = true)
        {
            var i = new ToolStripMenuItem(text) { Checked = check, Enabled = enabled };
            if (act != null) i.Click += (s, e) => act();
            return i;
        }

        ToolStripItem Info(string text)
        {
            var i = new ToolStripMenuItem(text) { Enabled = false };
            return i;
        }

        Timer menuCpuTimer;

        /// Readouts in the menu, only for what the taskbar strip isn't already showing: a gauge that's on screen
        /// doesn't need repeating here, and one that's hidden still gets a line.
        void AddReadouts()
        {
            if (!IsSegmentShown(Segment.Network))
            {
                var bits = Prefs.UseBits;
                menu.Items.Add(Info("▲ " + Fmt.Rate(Net.CurrentUp, bits, Prefs.NetUnit) + "    ▼ " + Fmt.Rate(Net.CurrentDown, bits, Prefs.NetUnit)));
            }
            if (!IsSegmentShown(Segment.Battery) && Battery != null) foreach (var l in BatteryMonitor.Describe(Battery)) menu.Items.Add(Info(l));
            if (!IsSegmentShown(Segment.Cpu))
            {
                // the meter isn't running, so take a fresh half-second reading now (kept updated while the menu is open)
                Cpu.Sample();
                var line = Info("CPU — measuring…");
                menu.Items.Add(line);
                menuCpuTimer?.Dispose();
                menuCpuTimer = new Timer { Interval = 500 };
                menuCpuTimer.Tick += (s, e) =>
                {
                    if (!menuOpen || line.IsDisposed) { menuCpuTimer.Stop(); return; }
                    Cpu.Sample();
                    line.Text = "CPU — " + Fmt.Pct(Cpu.Total) + "  ·  User " + Fmt.Pct(Cpu.User) + "  ·  System " + Fmt.Pct(Cpu.Sys);
                };
                menuCpuTimer.Start();
            }
            if (!IsSegmentShown(Segment.Disks))
            {
                try
                {
                    var root = System.IO.Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.System));
                    var d = new System.IO.DriveInfo(root);
                    if (d.IsReady) menu.Items.Add(Info((string.IsNullOrEmpty(d.VolumeLabel) ? "System drive" : d.VolumeLabel) + " (" + root.TrimEnd('\\') + ") — " +
                                                       Fmt.Bytes(d.AvailableFreeSpace) + " free of " + Fmt.Bytes(d.TotalSize)));
                }
                catch { }
            }
        }

        void BuildMenu()
        {
            menu.Items.Clear();
            LidDisabled = LidSleep.Available && LidSleep.IsDisabled;
            menu.Items.Add(Item("About BoostBar " + Updater.CurrentVersion + "…", AboutForm.ShowShared));
            AddReadouts();
            menu.Items.Add(new ToolStripSeparator());
            var head = new ToolStripMenuItem("KEEP AWAKE") { Enabled = false };
            head.Font = new Font(menu.Font.FontFamily, menu.Font.Size * 0.85f, FontStyle.Bold);
            menu.Items.Add(head);
            var title = "Keep PC Awake";
            if (Sleep.Until.HasValue) title += " (until " + Sleep.Until.Value.ToShortTimeString() + ")";
            menu.Items.Add(Item(title, ToggleKeepAwake, Sleep.IsPreventing));
            var forItem = new ToolStripMenuItem("Keep Awake For");
            foreach (var d in AwakeDurations.Skip(1)) { var m = d.Minutes; forItem.DropDownItems.Add(Item(d.Label, () => KeepAwakeFor(m))); }
            menu.Items.Add(forItem);
            menu.Items.Add(Item("    Keep Display On Too", () => SetKeepDisplayAwake(!Sleep.KeepDisplayAwake), Sleep.KeepDisplayAwake));
            if (LidSleep.Available) menu.Items.Add(Item("Stay Awake With Lid Closed", ToggleLidSleep, LidDisabled));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(Item("Settings…", () => SettingsForm.ShowShared(null)));
            menu.Items.Add(Item("Check for Updates…", () => Updater.Check(true)));
            menu.Items.Add(Item("Buy Mac an Energy Drink ⚡…", AboutForm.ShowShared));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(Item("Quit BoostBar", () => Application.Exit()));
        }

        // ---------------- actions ----------------

        public void ToggleKeepAwake() { if (Sleep.IsPreventing) Sleep.Allow(); else Sleep.Prevent(null); }
        public void KeepAwakeFor(int? minutes) => Sleep.Prevent(minutes.HasValue ? TimeSpan.FromMinutes(minutes.Value) : (TimeSpan?)null);
        public void SetKeepDisplayAwake(bool on) { Sleep.KeepDisplayAwake = on; Prefs.KeepDisplayAwake = on; }

        public void ToggleLidSleep()
        {
            var disable = !LidSleep.IsDisabled;
            if (disable && !Prefs.GetBool("lidWarningShown", false))
            {
                var r = MessageBox.Show(
                    "This sets your power plan's “When I close the lid” action to “Do nothing”, plugged in and on battery, " +
                    "so the PC keeps running with the lid closed. It stays that way after quitting or restarting until you turn it off here " +
                    "(BoostBar then puts back your previous setting).\n\nThe PC can still sleep when idle — turn on Keep Awake as well to stop that.\n\n" +
                    "Don't put a running laptop in a bag with this on; it can overheat and drain the battery.",
                    "Stay awake with the lid closed?", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
                if (r != DialogResult.OK) { SettingsForm.RefreshOpen(); return; }
                Prefs.SetBool("lidWarningShown", true);
            }
            if (!LidSleep.Set(disable))
                Updater.Alert("Couldn't change the lid setting", "Windows didn't allow the change. Your power plan may be managed by your organization.");
            LidDisabled = LidSleep.IsDisabled;
            ScreenSavers.MigrateRenamed();
            ApplySettings();
            SettingsForm.RefreshOpen();
        }

        public void SetPlacementFloating(bool floating) { Prefs.Placement = floating ? 1 : 0; }

        void HotCorner(Corner c, Screen screen)
        {
            if (c == Prefs.CornerSaver)
            {
                Toast.Flash("Screen saver…", c, screen);
                var t = new Timer { Interval = 500 };
                t.Tick += (s, e) => { t.Stop(); t.Dispose(); ScreenSavers.StartNow(); };
                t.Start();
                return;
            }
            if (c == Prefs.CornerSleep)
            {
                Toast.Flash("Sleeping…", c, screen);
                Sleep.Allow();
                var t = new Timer { Interval = 800 };
                t.Tick += (s, e) => { t.Stop(); t.Dispose(); SleepNow.Go(); };
                t.Start();
                return;
            }
            if (c == Prefs.CornerAwake)
            {
                ToggleKeepAwake();
                Toast.Flash(Sleep.IsPreventing ? "☕  Keep Awake ON" : "🌙  Keep Awake OFF", c, screen);
            }
        }

        public string NetworkSummary()
        {
            var l = Net.ActiveLinks;
            if (l.Count == 0) return "No active connections right now.";
            var list = string.Join(", ", l.Select(x => x.Short + " (" + x.Name + ")"));
            return l.Count > 1 ? "Connected now: " + list + ". Separate graphs show when two or more are connected."
                               : "Connected now: " + list + ". A second connection gets its own graph.";
        }

        public bool IsSegmentShown(Segment s)
        {
            switch (s)
            {
                case Segment.Eyes: return Prefs.ShowEyes;
                case Segment.Network: return Prefs.ShowNetwork;
                case Segment.Battery: return Prefs.ShowBattery && BatteryMonitor.HasBattery;
                case Segment.Disks: return Prefs.ShowDisks;
                default: return Prefs.ShowCPU;
            }
        }
    }
}
