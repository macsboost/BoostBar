using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Linq;

namespace BoostBar
{
    enum AwakeState { Normal, KeepAwake, LidAwake }

    /// What the strip is pointing at under the mouse.
    class HoverTarget : IEquatable<HoverTarget>
    {
        public enum K { Network, Battery, Disk, Cpu }
        public K Kind; public string Id;
        public bool Equals(HoverTarget o) => o != null && o.Kind == Kind && o.Id == Id;
        public override bool Equals(object o) => Equals(o as HoverTarget);
        public override int GetHashCode() => ((int)Kind * 397) ^ (Id?.GetHashCode() ?? 0);
    }

    /// Draws the BoostBar strip — a port of the Mac StatusGraphView — in logical units (y down).
    /// The layout band is 24 units tall; the window scales it to the taskbar.
    class StripRenderer
    {
        public const float BandHeight = 24;

        public class NetRow { public string Id; public NetLink.LinkKind Kind; public double[] Up, Down; public string UpText, DownText; }
        public class Led { public string Key; public Color Color; }

        // content
        public double[] Up = new double[30], Down = new double[30];
        public string UpText = "0.0 KB/s", DownText = "0.0 KB/s";
        public List<NetRow> NetRows = new List<NetRow>();
        public bool VerticalLabels;
        public AwakeState Awake = AwakeState.Normal;
        public bool EyesShowAwake;
        public BatteryReading Battery;
        public List<Led> Leds = new List<Led>();
        public HashSet<string> LitKeys = new HashSet<string>();
        public Color UpColor = Color.White, DownColor = Color.White;
        public bool ShowNetwork = true, ShowBattery, ShowDisks = true, ShowEyes, ShowCPU;
        public double Cpu; public double[] CpuCores = new double[0]; public int CpuStyle; public double CpuBackdrop; public double[] CpuPeaks = new double[0];
        public int LedSize;
        public int EyeSize = 1; public bool SingleEye, Bloodshot, Pirate;
        /// Eyelashes: 0 none, 1 natural, 2 fake.
        public int Lashes;
        public PointF[] PupilOffsets = new PointF[0];
        public float? WheelAngle;
        public bool EyesClosed;
        /// The mood the eyes are showing (lids, slant, pupil size, props); plain by default.
        public EyeFace Face = new EyeFace();
        public Segment[] Order = Prefs.DefaultOrder;
        public Fmt.NetUnit NetUnit = Fmt.NetUnit.Auto; public bool NetBits;
        public bool LightBar;
        public Segment? Dragging;

        // layout
        const float Pad = 3, DotWidth = 6, GraphWidth = 30, LinkIconWidth = 13, IconWidth = 20, GaugeWidth = 27, LabelWidth = 7;
        static readonly float[] LedDiameters = { 7, 11, 15 };
        static readonly SizeF[] EyeSizes = { new SizeF(9, 13), new SizeF(12, 17), new SizeF(15, 20) };
        public RectangleF NetworkRect, BatteryRect, DiskRect, EyesRect, CpuRect;
        readonly List<(string Id, RectangleF Rect)> netRowRects = new List<(string, RectangleF)>();
        readonly List<(string Key, RectangleF Rect)> ledRects = new List<(string, RectangleF)>();
        public readonly List<RectangleF> EyeRects = new List<RectangleF>();
        readonly List<(string Text, RectangleF Rect)> labelRects = new List<(string, RectangleF)>();

        static readonly Font TextFont = new Font("Segoe UI Semibold", 9.4f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly Font SmallHeavy = new Font("Segoe UI Black", 8.2f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly Font LabelFont = new Font("Segoe UI Black", 6.6f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly StringFormat Typo = MakeTypo();
        static StringFormat MakeTypo() { var f = (StringFormat)StringFormat.GenericTypographic.Clone(); f.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap; return f; }
        static Font iconFont;
        static Font IconFont
        {
            get
            {
                if (iconFont != null) return iconFont;
                foreach (var name in new[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" })
                {
                    try
                    {
                        using (var fams = new InstalledFontCollection())
                            if (fams.Families.Any(f => f.Name == name)) return iconFont = new Font(name, 9f, FontStyle.Regular, GraphicsUnit.Pixel);
                    }
                    catch { }
                }
                return iconFont = new Font("Segoe UI Symbol", 9f, FontStyle.Regular, GraphicsUnit.Pixel);
            }
        }

        static readonly Graphics Measurer = Graphics.FromImage(new Bitmap(1, 1));
        static float Measure(string s, Font f) => Measurer.MeasureString(s, f, 1000, Typo).Width;

        Color Ink => LightBar ? Color.FromArgb(235, 20, 20, 20) : Color.FromArgb(240, 255, 255, 255);
        static Color A(Color c, double a) => Color.FromArgb((int)Math.Max(0, Math.Min(255, c.A * a)), c.R, c.G, c.B);

        bool ShowsAwakeDot =>
            Awake == AwakeState.LidAwake || (Awake == AwakeState.KeepAwake && !(EyesShowAwake && ShowEyes));
        bool ShowsBattery => ShowBattery && Battery != null;
        bool ShowsDisks => ShowDisks && Leds.Count > 0;
        bool ShowsAnything => ShowNetwork || ShowsBattery || ShowsDisks || ShowEyes || ShowCPU;
        SizeF EyeDims => EyeSizes[Math.Min(Math.Max(EyeSize, 0), 2)];
        float PupilRadius => EyeDims.Width * 0.27f;
        public SizeF PupilTravel => new SizeF(EyeDims.Width / 2 - PupilRadius - 1, EyeDims.Height / 2 - PupilRadius - 1);

        float NetTextWidth
        {
            get
            {
                var u = NetBits ? "b/s" : "B/s";
                var sample = NetUnit == Fmt.NetUnit.Mega ? "88.88 M" + u : "888 K" + u;
                return (float)Math.Ceiling(TriangleWidth + 3 + Measure(sample, TextFont));
            }
        }
        const float TriangleWidth = 6;

        float BatteryTextWidth
        {
            get
            {
                if (Battery == null) return 28;
                var (top, bottom, _) = BatteryTexts(Battery);
                return (float)Math.Ceiling(Math.Max(Measure(top, TextFont), Measure(bottom, SmallHeavy))) + 1;
            }
        }

        static float CpuBarPitch(int cores) => cores > 12 ? 2 : cores > 8 ? 3 : 4;

        /// Lays out the segments and returns the total width needed.
        public float Layout()
        {
            const float h = BandHeight;
            float x = Pad;
            if (ShowsAwakeDot || !ShowsAnything) x += DotWidth;
            netRowRects.Clear(); labelRects.Clear(); ledRects.Clear(); EyeRects.Clear();
            NetworkRect = BatteryRect = DiskRect = EyesRect = CpuRect = RectangleF.Empty;
            if (!ShowsAnything) return x + IconWidth + Pad;

            var first = true;
            Segment? prev = null;
            void Gap(float w = 4) { if (!first) x += w; first = false; }
            void Label(string text)
            {
                if (!VerticalLabels) return;
                labelRects.Add((text, new RectangleF(x, 0, LabelWidth, h)));
                x += LabelWidth + 2;
            }

            foreach (var seg in Order)
            {
                var before = x;
                switch (seg)
                {
                    case Segment.Eyes:
                        if (!ShowEyes) break;
                        Gap();
                        var e = EyeDims;
                        // lashes need a little room: beside the outer corners, and above (the eyes sit a touch lower and shorter)
                        var lp = Lashes == 0 ? 0f : (float)Math.Ceiling(e.Width * (Lashes == 2 ? 0.36f : 0.2f));
                        var lv = Lashes == 0 ? 0f : (Lashes == 2 ? 3f : 2f);
                        var eh = Math.Min(e.Height, h - 2 - lv);
                        var count = SingleEye ? 1 : 2;
                        for (var i = 0; i < count; i++) EyeRects.Add(new RectangleF(x + lp + i * (e.Width + 1), (h - eh) / 2 + lv / 2, e.Width, eh));
                        EyesRect = new RectangleF(x, 0, count * e.Width + (count - 1) + lp * 2, h);
                        x = EyesRect.Right;
                        break;
                    case Segment.Network:
                        if (!ShowNetwork) break;
                        Gap(); Label("NET");
                        if (NetRows.Count >= 2)
                        {
                            var start = x;
                            for (var i = 0; i < NetRows.Count; i++)
                            {
                                if (i > 0) x += 5;
                                var r = new RectangleF(x, 0, LinkIconWidth + GraphWidth + 4 + NetTextWidth, h);
                                netRowRects.Add((NetRows[i].Id, r));
                                x = r.Right;
                            }
                            NetworkRect = new RectangleF(start, 0, x - start, h);
                        }
                        else
                        {
                            NetworkRect = new RectangleF(x, 0, GraphWidth + 4 + NetTextWidth, h);
                            x = NetworkRect.Right;
                        }
                        break;
                    case Segment.Battery:
                        if (!ShowsBattery) break;
                        Gap(3); Label("BAT");
                        BatteryRect = new RectangleF(x, 0, BatteryTextWidth, h);
                        x = BatteryRect.Right;
                        break;
                    case Segment.Cpu:
                        if (!ShowCPU) break;
                        Gap(prev == Segment.Disks ? 6 : 4); Label("CPU");
                        var n = Math.Max(CpuCores.Length, 1);
                        var w = CpuStyle == 1 ? n * CpuBarPitch(n) + 1 : GaugeWidth;
                        CpuRect = new RectangleF(x, 0, w, h);
                        x = CpuRect.Right;
                        break;
                    case Segment.Disks:
                        if (!ShowsDisks) break;
                        Gap(prev == Segment.Cpu ? 6 : 2); Label("HDD");
                        var dia = LedDiameters[Math.Min(Math.Max(LedSize, 0), 2)];
                        var cell = dia + 2;
                        var rows = LedSize == 0 && Leds.Count > 1 ? 2 : 1;
                        var cols = (int)Math.Ceiling(Leds.Count / (double)rows);
                        DiskRect = new RectangleF(x, 0, cols * cell, h);
                        for (var i = 0; i < Leds.Count; i++)
                        {
                            int col = i / rows, row = i % rows;
                            var cy = rows == 1 ? h / 2 : (row == 0 ? h / 2 - 4.5f : h / 2 + 4.5f);
                            ledRects.Add((Leds[i].Key, new RectangleF(x + col * cell + 0.5f, cy - dia / 2, dia, dia)));
                        }
                        x = DiskRect.Right;
                        break;
                }
                if (x != before) prev = seg;
            }
            return x + Pad;
        }

        public RectangleF RectOf(Segment s)
        {
            switch (s)
            {
                case Segment.Eyes: return EyesRect;
                case Segment.Network: return NetworkRect;
                case Segment.Battery: return BatteryRect;
                case Segment.Cpu: return CpuRect;
                default: return DiskRect;
            }
        }

        public Segment? SegmentAt(PointF p)
        {
            foreach (var s in Order)
            {
                var r = RectOf(s);
                if (!r.IsEmpty && p.X >= r.Left - 2 && p.X <= r.Right + 2) return s;
            }
            return null;
        }

        static bool InX(RectangleF r, PointF p, float slop) => !r.IsEmpty && p.X >= r.Left - slop && p.X <= r.Right + slop;

        public HoverTarget TargetAt(PointF p)
        {
            if (InX(NetworkRect, p, 2))
            {
                foreach (var nr in netRowRects) if (InX(nr.Rect, p, 3)) return new HoverTarget { Kind = HoverTarget.K.Network, Id = nr.Id };
                return new HoverTarget { Kind = HoverTarget.K.Network };
            }
            if (InX(BatteryRect, p, 2)) return new HoverTarget { Kind = HoverTarget.K.Battery };
            if (InX(CpuRect, p, 2)) return new HoverTarget { Kind = HoverTarget.K.Cpu };
            if (InX(DiskRect, p, 2) && ledRects.Count > 0)
            {
                var best = ledRects.OrderBy(l => Math.Pow(l.Rect.X + l.Rect.Width / 2 - p.X, 2) + Math.Pow(l.Rect.Y + l.Rect.Height / 2 - p.Y, 2)).First();
                return new HoverTarget { Kind = HoverTarget.K.Disk, Id = best.Key };
            }
            return null;
        }

        public RectangleF RectFor(HoverTarget t)
        {
            switch (t.Kind)
            {
                case HoverTarget.K.Network: return t.Id != null ? netRowRects.FirstOrDefault(r => r.Id == t.Id).Rect : NetworkRect;
                case HoverTarget.K.Battery: return BatteryRect;
                case HoverTarget.K.Cpu: return CpuRect;
                default:
                    var l = ledRects.FirstOrDefault(r => r.Key == t.Id).Rect;
                    return l.IsEmpty ? DiskRect : RectangleF.Inflate(l, 4, 8);
            }
        }

        // ---------------- drawing ----------------

        public void Draw(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;   // grayscale: ClearType can't do per-pixel alpha
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            const float h = BandHeight, mid = h / 2;
            var ink = Ink;

            if (ShowsAwakeDot)
                using (var b = new SolidBrush(Awake == AwakeState.LidAwake ? Palette.SystemOrange : Palette.SystemYellow))
                    g.FillEllipse(b, Pad, mid - 2, 4, 4);

            if (!ShowsAnything) { DrawIdleIcon(g, Pad + DotWidth, ink); return; }

            if (Dragging.HasValue)
            {
                var r = RectOf(Dragging.Value); r.Inflate(2, -1);
                using (var b = new SolidBrush(Color.FromArgb(90, 0, 120, 215))) FillRound(g, b, r, 4);
            }

            foreach (var l in labelRects) DrawVerticalLabel(g, l.Text, l.Rect, ink);
            if (ShowCPU && !CpuRect.IsEmpty) { if (CpuStyle == 1) DrawCpuBars(g, CpuRect); else DrawCpuGauge(g, CpuRect); }
            if (ShowNetwork)
            {
                if (netRowRects.Count == 0) DrawNetwork(g, NetworkRect, Up, Down, UpText, DownText, ink);
                else
                    for (var i = 0; i < Math.Min(NetRows.Count, netRowRects.Count); i++)
                    {
                        var row = NetRows[i]; var r = netRowRects[i].Rect;
                        var glyph = row.Kind == NetLink.LinkKind.WiFi ? "" : row.Kind == NetLink.LinkKind.Ethernet ? "" : "";
                        using (var b = new SolidBrush(A(ink, 0.85)))
                        {
                            var sz = g.MeasureString(glyph, IconFont, 100, Typo);
                            g.DrawString(glyph, IconFont, b, r.X + (LinkIconWidth - 2 - sz.Width) / 2, (h - sz.Height) / 2 + 0.5f, Typo);
                        }
                        var gr = new RectangleF(r.X + LinkIconWidth, r.Y, r.Width - LinkIconWidth, r.Height);
                        DrawNetwork(g, gr, row.Up, row.Down, row.UpText, row.DownText, ink);
                    }
            }
            if (ShowsBattery) DrawBattery(g, Battery, BatteryRect, ink);
            if (ShowsDisks) DrawDisks(g, ink);
            if (ShowEyes) { DrawEyes(g); DrawLashes(g); DrawEyepatch(g); }
        }

        static void FillRound(Graphics g, Brush b, RectangleF r, float rad)
        {
            using (var p = RoundRect(r, rad)) g.FillPath(b, p);
        }

        static GraphicsPath RoundRect(RectangleF r, float rad)
        {
            var p = new GraphicsPath();
            var d = Math.Min(rad * 2, Math.Min(r.Width, r.Height));
            if (d <= 0.1f) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        void DrawIdleIcon(Graphics g, float x, Color ink)
        {
            // a small gauge: arc and needle
            var c = new PointF(x + IconWidth / 2, BandHeight / 2 + 4);
            using (var pen = new Pen(ink, 1.8f)) g.DrawArc(pen, c.X - 7, c.Y - 7, 14, 14, 180, 180);
            using (var pen = new Pen(ink, 1.6f) { StartCap = LineCap.Round, EndCap = LineCap.Round }) g.DrawLine(pen, c, new PointF(c.X - 3.5f, c.Y - 4.5f));
            using (var b = new SolidBrush(ink)) g.FillEllipse(b, c.X - 1.6f, c.Y - 1.6f, 3.2f, 3.2f);
        }

        // ---- network ----
        Color TraceColor(Color c) => LightBar && c.R > 230 && c.G > 230 && c.B > 230 ? Color.FromArgb(235, 20, 20, 20) : c;

        static void Triangle(Graphics g, Brush b, float x, float cy, bool upward)
        {
            const float w = TriangleWidth, hh = 5.2f;
            var pts = upward
                ? new[] { new PointF(x, cy + hh / 2), new PointF(x + w, cy + hh / 2), new PointF(x + w / 2, cy - hh / 2) }
                : new[] { new PointF(x, cy - hh / 2), new PointF(x + w, cy - hh / 2), new PointF(x + w / 2, cy + hh / 2) };
            g.FillPolygon(b, pts);
        }

        void DrawNetwork(Graphics g, RectangleF r, double[] up, double[] down, string upText, string downText, Color ink)
        {
            var upC = TraceColor(UpColor); var downC = TraceColor(DownColor);
            var gr = new RectangleF(r.X, 3, GraphWidth, BandHeight - 6);
            using (var b = new SolidBrush(A(ink, 0.12))) FillRound(g, b, gr, 2);
            var mid = gr.Y + gr.Height / 2;
            var half = gr.Height / 2 - 0.5f;
            var n = Math.Max(up.Length, 1);
            var barW = gr.Width / n;
            const double floorScale = 2000;   // don't amplify idle noise below ~2 KB/s
            var maxUp = Math.Max(up.Length > 0 ? up.Max() : 0, floorScale);
            var maxDown = Math.Max(down.Length > 0 ? down.Max() : 0, floorScale);
            var old = g.SmoothingMode; g.SmoothingMode = SmoothingMode.None;
            using (var b = new SolidBrush(upC))
                for (var i = 0; i < up.Length; i++)
                    if (up[i] > 0) { var bh = Math.Max((float)(up[i] / maxUp) * half, 0.5f); g.FillRectangle(b, gr.X + i * barW, mid - 0.5f - bh, barW, bh); }
            using (var b = new SolidBrush(downC))
                for (var i = 0; i < down.Length; i++)
                    if (down[i] > 0) { var bh = Math.Max((float)(down[i] / maxDown) * half, 0.5f); g.FillRectangle(b, gr.X + i * barW, mid + 0.5f, barW, bh); }
            using (var b = new SolidBrush(A(ink, 0.35))) g.FillRectangle(b, gr.X, mid - 0.5f, gr.Width, 1);
            g.SmoothingMode = old;

            var tx = gr.Right + 4;
            var lineH = TextFont.GetHeight();
            using (var ub = new SolidBrush(upC)) Triangle(g, ub, tx, mid - lineH / 2 - 0.2f, true);
            using (var db = new SolidBrush(downC)) Triangle(g, db, tx, mid + lineH / 2 + 0.6f, false);
            using (var t = new SolidBrush(ink))
            {
                g.DrawString(upText, TextFont, t, tx + TriangleWidth + 3, mid - lineH - 0.2f + 0.6f, Typo);
                g.DrawString(downText, TextFont, t, tx + TriangleWidth + 3, mid + 0.6f, Typo);
            }
        }

        // ---- battery ----
        static (string Top, string Bottom, int Mode) BatteryTexts(BatteryReading b)
        {
            switch (b.Direction)
            {
                case BatteryReading.Dir.Charging: return (Fmt.Watts(b.Watts), "IN", 0);
                case BatteryReading.Dir.Discharging: return (Fmt.Watts(b.Watts), "OUT", 1);
                default: return (b.Percent.HasValue ? b.Percent + "%" : "0.0W", b.ExternalConnected ? "AC" : "IDLE", 2);
            }
        }

        void DrawBattery(Graphics g, BatteryReading b, RectangleF r, Color ink)
        {
            var (top, bottom, mode) = BatteryTexts(b);
            var color = mode == 0 ? Palette.SystemGreen : mode == 1 ? Palette.SystemOrange : (b.ExternalConnected ? ink : A(ink, 0.55));
            const float mid = BandHeight / 2;
            using (var t = new SolidBrush(ink))
            {
                var w = Measure(top, TextFont);
                g.DrawString(top, TextFont, t, r.X + (r.Width - w) / 2, mid - TextFont.GetHeight() + 0.4f, Typo);
            }
            using (var c = new SolidBrush(color))
            {
                var w = Measure(bottom, SmallHeavy);
                g.DrawString(bottom, SmallHeavy, c, r.X + (r.Width - w) / 2, mid + 1.2f, Typo);
            }
        }

        // ---- CPU ----
        bool MeterOnLight => CpuBackdrop > 0.35 ? true : CpuBackdrop < -0.35 ? false : LightBar;
        Color MeterInk => MeterOnLight == LightBar ? Ink : (MeterOnLight ? Color.FromArgb(255, 26, 26, 26) : Color.FromArgb(255, 242, 242, 242));
        Color BackdropColor => Color.FromArgb((int)(Math.Min(1, Math.Abs(CpuBackdrop)) * 0.7 * 255), CpuBackdrop < 0 ? Color.Black : Color.White);

        /// Boost-gauge colours: green, lime, yellow, orange, red — deepened on a light background.
        Color BoostColor(double x)
        {
            var stops = new (double T, double[] C)[]
            {
                (0, new double[] { 62, 220, 64 }), (0.28, new double[] { 196, 236, 34 }), (0.45, new double[] { 250, 214, 20 }),
                (0.66, new double[] { 250, 128, 22 }), (0.82, new double[] { 236, 34, 40 }), (1, new double[] { 236, 30, 42 }),
            };
            var i = 1;
            while (i < stops.Length - 1 && stops[i].T < x) i++;
            var a = stops[i - 1]; var b = stops[i];
            var k = Math.Min(1, Math.Max(0, (x - a.T) / (b.T - a.T)));
            var c = new double[3];
            for (var j = 0; j < 3; j++) c[j] = a.C[j] + (b.C[j] - a.C[j]) * k;
            if (MeterOnLight) { c[0] *= 0.80; c[1] *= 0.66; c[2] *= 0.62; }
            return Color.FromArgb((int)c[0], (int)c[1], (int)c[2]);
        }

        void DrawCpuGauge(Graphics g, RectangleF r)
        {
            var x = Math.Min(1, Math.Max(0, Cpu));
            var c = new PointF(r.X + r.Width / 2, r.Y + r.Height / 2 + 5.5f);
            var R = Math.Min(r.Width / 2 - 0.5f, r.Height - 8);
            if (CpuBackdrop != 0)
            {
                float pr = R + 1.6f, foot = 3.4f;
                using (var p = new GraphicsPath())
                {
                    p.AddArc(c.X - pr, c.Y - pr, pr * 2, pr * 2, 180, 180);
                    p.AddLine(c.X + pr, c.Y, c.X + pr, c.Y + foot - 2);
                    p.AddArc(c.X + pr - 4, c.Y + foot - 4, 4, 4, 0, 90);
                    p.AddLine(c.X + pr - 2, c.Y + foot, c.X - pr + 2, c.Y + foot);
                    p.AddArc(c.X - pr, c.Y + foot - 4, 4, 4, 90, 90);
                    p.CloseFigure();
                    using (var b = new SolidBrush(BackdropColor)) g.FillPath(b, p);
                }
            }
            float Ang(double t) => (float)(180 * t - 180);   // GDI+ degrees, clockwise from 3 o'clock
            double[] gaps = { 0.16, 0.36, 0.56, 0.74, 0.88 };
            const int n = 60;
            for (var i = 0; i < n; i++)
            {
                double t0 = i / (double)n, t1 = (i + 1) / (double)n, tm = (t0 + t1) / 2;
                if (gaps.Any(q => Math.Abs(tm - q) < 0.02)) continue;
                var w = 1.6f + 3.4f * (float)Math.Pow(tm, 1.35);
                using (var p = new GraphicsPath())
                {
                    var a0 = Ang(t0);
                    var sweep = Math.Max(0.1f, Ang(t1) - a0 - 0.6f);
                    p.AddArc(c.X - R, c.Y - R, R * 2, R * 2, a0, sweep);
                    var ri = R - w;
                    p.AddArc(c.X - ri, c.Y - ri, ri * 2, ri * 2, a0 + sweep, -sweep);
                    p.CloseFigure();
                    var col = tm <= x + 0.002 ? BoostColor(tm) : A(MeterInk, MeterOnLight ? 0.2 : 0.24);
                    using (var b = new SolidBrush(col)) g.FillPath(b, p);
                }
            }
            var ang = Ang(x) * Math.PI / 180;
            var len = R - 1.5f;
            var tip = new PointF(c.X + (float)Math.Cos(ang) * len, c.Y + (float)Math.Sin(ang) * len);
            var side = new PointF(-(float)Math.Sin(ang) * 1.1f, (float)Math.Cos(ang) * 1.1f);
            using (var b = new SolidBrush(MeterInk))
            {
                g.FillPolygon(b, new[] { new PointF(c.X + side.X, c.Y + side.Y), tip, new PointF(c.X - side.X, c.Y - side.Y) });
                g.FillEllipse(b, c.X - 1.8f, c.Y - 1.8f, 3.6f, 3.6f);
            }
        }

        void DrawCpuBars(Graphics g, RectangleF r)
        {
            var cores = CpuCores.Length == 0 ? new[] { Cpu } : CpuCores;
            var pitch = CpuBarPitch(cores.Length);
            var gr = new RectangleF(r.X, 3, r.Width, r.Height - 6);
            if (CpuBackdrop != 0)
                using (var b = new SolidBrush(BackdropColor)) FillRound(g, b, RectangleF.Inflate(gr, 1.5f, 1.5f), 3);
            var old = g.SmoothingMode; g.SmoothingMode = SmoothingMode.None;
            using (var slotB = new SolidBrush(A(MeterInk, 0.14)))
            using (var peakB = new SolidBrush(A(MeterInk, 0.9)))
                for (var i = 0; i < cores.Length; i++)
                {
                    var v = cores[i];
                    var slot = new RectangleF(gr.X + i * pitch + 0.5f, gr.Y, pitch - 1, gr.Height);
                    g.FillRectangle(slotB, slot);
                    var hgt = Math.Max(1, slot.Height * (float)Math.Min(1, Math.Max(0, v)));
                    using (var b = new SolidBrush(BoostColor(v))) g.FillRectangle(b, slot.X, slot.Bottom - hgt, slot.Width, hgt);
                    if (i < CpuPeaks.Length && CpuPeaks[i] > v + 0.03)
                    {
                        var py = slot.Bottom - slot.Height * (float)Math.Min(1, CpuPeaks[i]);
                        g.FillRectangle(peakB, slot.X, Math.Max(slot.Y, py), slot.Width, 1);
                    }
                }
            g.SmoothingMode = old;
        }

        void DrawVerticalLabel(Graphics g, string text, RectangleF r, Color color)
        {
            var step = Math.Min(7f, (r.Height - 1) / Math.Max(text.Length, 1));
            var top = r.Y + r.Height / 2 - step * (text.Length - 1) / 2;
            using (var b = new SolidBrush(A(color, 0.92)))
                for (var i = 0; i < text.Length; i++)
                {
                    var s = text[i].ToString();
                    var sz = g.MeasureString(s, LabelFont, 100, Typo);
                    g.DrawString(s, LabelFont, b, r.X + (r.Width - sz.Width) / 2, top + i * step - sz.Height / 2, Typo);
                }
        }

        // ---- disks ----
        void DrawDisks(Graphics g, Color ink)
        {
            for (var i = 0; i < Math.Min(ledRects.Count, Leds.Count); i++)
            {
                var led = Leds[i]; var r = ledRects[i].Rect;
                if (LitKeys.Contains(ledRects[i].Key))
                {
                    using (var glow = new SolidBrush(Color.FromArgb(70, led.Color))) g.FillEllipse(glow, RectangleF.Inflate(r, 1.6f, 1.6f));
                    using (var glow = new SolidBrush(Color.FromArgb(110, led.Color))) g.FillEllipse(glow, RectangleF.Inflate(r, 0.8f, 0.8f));
                    using (var b = new SolidBrush(led.Color)) g.FillEllipse(b, r);
                }
                else
                {
                    using (var b = new SolidBrush(Color.FromArgb(46, led.Color))) g.FillEllipse(b, r);
                    using (var p = new Pen(A(ink, 0.35), 0.75f)) g.DrawEllipse(p, r);
                }
            }
        }

        // ---- eyes ----
        void DrawEyes(Graphics g)
        {
            var patched = Pirate && EyeRects.Count > 1 ? 0 : -1;
            var face = Face ?? new EyeFace();
            var pr = PupilRadius * face.PupilScale;
            for (var i = 0; i < EyeRects.Count; i++)
            {
                if (i == patched) continue;
                var r0 = EyeRects[i];
                var r = new RectangleF(r0.X, r0.Y - Math.Min(face.Lift, r0.Y), r0.Width, r0.Height);
                var er = RectangleF.Inflate(r, -0.5f, -0.5f);
                using (var eye = new GraphicsPath())
                {
                    eye.AddEllipse(er);
                    if (face.Smile && !EyesClosed)
                    {
                        // happy: closed, arched eyes
                        using (var lg = new LinearGradientBrush(new RectangleF(er.X, er.Y - 0.5f, er.Width, er.Height + 1), Color.White, Color.FromArgb(219, 219, 219), 90f))
                            g.FillPath(lg, eye);
                        var my = r.Y + r.Height / 2;
                        using (var pen = new Pen(Color.Black, Math.Max(1.4f, r.Width * 0.13f)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                            g.DrawBezier(pen, r.X + 2, my + r.Height * 0.08f, r.X + r.Width * 0.3f, my - r.Height * 0.3f,
                                         r.Right - r.Width * 0.3f, my - r.Height * 0.3f, r.Right - 2, my + r.Height * 0.08f);
                    }
                    else if (EyesClosed)
                    {
                        using (var b = new SolidBrush(Color.FromArgb(217, 217, 217))) g.FillPath(b, eye);
                        using (var lid = new Pen(Color.Black, 1.2f))
                            g.DrawBezier(lid, r.X + 1.5f, r.Y + r.Height / 2, r.X + r.Width * 0.3f, r.Y + r.Height / 2 + r.Height * 0.18f,
                                         r.Right - r.Width * 0.3f, r.Y + r.Height / 2 + r.Height * 0.18f, r.Right - 1.5f, r.Y + r.Height / 2);
                    }
                    else
                    {
                        var top = Bloodshot ? Color.FromArgb(255, 242, 240) : Color.White;
                        var bottom = Bloodshot ? Color.FromArgb(250, 184, 184) : Color.FromArgb(209, 209, 209);
                        using (var lg = new LinearGradientBrush(new RectangleF(er.X, er.Y - 0.5f, er.Width, er.Height + 1), top, bottom, 90f))
                            g.FillPath(lg, eye);
                        if (Bloodshot) DrawVeins(g, r, eye, i);
                        void Pupil(PointF c, float squash = 1)
                        {
                            if (face.Symbol == 1)
                            {
                                // a heart
                                var s = pr * 1.25f;
                                using (var h = new GraphicsPath())
                                {
                                    h.AddBezier(c.X, c.Y + s, c.X - s * 0.5f, c.Y + s * 0.55f, c.X - s, c.Y + s * 0.15f, c.X - s, c.Y - s * 0.25f);
                                    h.AddBezier(c.X - s, c.Y - s * 0.25f, c.X - s, c.Y - s * 0.95f, c.X - s * 0.15f, c.Y - s * 0.95f, c.X, c.Y - s * 0.45f);
                                    h.AddBezier(c.X, c.Y - s * 0.45f, c.X + s * 0.15f, c.Y - s * 0.95f, c.X + s, c.Y - s * 0.95f, c.X + s, c.Y - s * 0.25f);
                                    h.AddBezier(c.X + s, c.Y - s * 0.25f, c.X + s, c.Y + s * 0.15f, c.X + s * 0.5f, c.Y + s * 0.55f, c.X, c.Y + s);
                                    using (var b = new SolidBrush(Color.FromArgb(237, 28, 61))) g.FillPath(b, h);
                                }
                                return;
                            }
                            if (face.Symbol == 2)
                            {
                                using (var f = new Font("Segoe UI", pr * 3.0f, FontStyle.Bold, GraphicsUnit.Pixel))
                                using (var b = new SolidBrush(Color.FromArgb(26, 140, 41)))
                                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                                    g.DrawString("$", f, b, new RectangleF(c.X - pr * 3, c.Y - pr * 3, pr * 6, pr * 6), sf);
                                return;
                            }
                            var w = pr * 2 * squash;
                            using (var b = new SolidBrush(Color.Black)) g.FillEllipse(b, c.X - w / 2, c.Y - pr, w, pr * 2);
                            var gl = Math.Max(pr * 0.35f, 0.8f);
                            using (var b = new SolidBrush(Color.FromArgb((int)(230 * squash), 255, 255, 255)))
                                g.FillEllipse(b, c.X - pr * 0.45f * squash, c.Y - pr * 0.15f - gl, gl * squash, gl);
                        }
                        if (WheelAngle.HasValue)
                        {
                            var state = g.Save();
                            g.SetClip(eye);
                            var span = EyesRect.Width / 2 + 1;
                            for (var k = 0; k < 4; k++)
                            {
                                var a = WheelAngle.Value + k * Math.PI / 2;
                                var depth = Math.Cos(a);
                                if (depth <= 0) continue;
                                var x = EyesRect.X + EyesRect.Width / 2 + span * (float)Math.Sin(a);
                                Pupil(new PointF(x, r.Y + r.Height / 2 + pr * 0.15f), (float)Math.Max(0.35, depth));
                            }
                            g.Restore(state);
                        }
                        else
                        {
                            var off = i < PupilOffsets.Length ? PupilOffsets[i] : PointF.Empty;
                            if (face.Symbol != 0) off = PointF.Empty;
                            Pupil(new PointF(r.X + r.Width / 2 + off.X, r.Y + r.Height / 2 + off.Y));
                        }
                        // lids: the upper one can slant (toward the middle when angry, toward the outside when sad);
                        // a one-eye squint (skeptical) closes this eye's lids further
                        var sq = EyeRects.Count > 1 ? (i == 0 ? face.SquintL : face.SquintR) : Math.Max(face.SquintL, face.SquintR);
                        var lt = Math.Max(face.LidTop, sq * 0.62f); var lb = Math.Max(face.LidBottom, sq * 0.42f);
                        if (lt > 0.01f || lb > 0.01f)
                        {
                            var st = g.Save();
                            g.SetClip(eye);
                            var lidFill = Bloodshot ? Color.FromArgb(189, 189, 189) : Color.FromArgb(199, 199, 199);
                            if (lt > 0.01f)
                            {
                                var innerIsRight = EyeRects.Count > 1 ? i == 0 : true;
                                var slant = EyeRects.Count > 1 ? face.Slant : 0;
                                float inner = Math.Max(0, lt + slant), outer = Math.Max(0, lt - slant * 0.6f);
                                var yL = r.Y + r.Height * (innerIsRight ? outer : inner);
                                var yR = r.Y + r.Height * (innerIsRight ? inner : outer);
                                using (var lid = new GraphicsPath())
                                {
                                    lid.AddPolygon(new[] { new PointF(r.X - 1, r.Y - 1), new PointF(r.Right + 1, r.Y - 1), new PointF(r.Right + 1, yR), new PointF(r.X - 1, yL) });
                                    using (var b = new SolidBrush(lidFill)) g.FillPath(b, lid);
                                }
                                using (var pen = new Pen(Color.Black, Math.Abs(slant) > 0.05f ? 1.5f : 1f)) g.DrawLine(pen, r.X - 1, yL, r.Right + 1, yR);
                            }
                            if (lb > 0.01f)
                            {
                                var y = r.Bottom - r.Height * lb;
                                using (var b = new SolidBrush(lidFill)) g.FillRectangle(b, r.X - 1, y, r.Width + 2, r.Bottom - y + 1);
                                using (var pen = new Pen(Color.Black, 1f)) g.DrawLine(pen, r.X - 1, y, r.Right + 1, y);
                            }
                            g.Restore(st);
                        }
                    }
                    var rim = Bloodshot && !EyesClosed ? Color.FromArgb(153, 13, 20) : Color.FromArgb(217, 0, 0, 0);
                    using (var p = new Pen(rim, 1f)) g.DrawPath(p, eye);
                }
            }
            if (face.Sweat >= 0 && EyeRects.Count > 0)
            {
                // a sweat drop sliding down beside the eye
                var r = EyeRects[EyeRects.Count - 1];
                var w = Math.Max(2.6f, r.Width * 0.26f); var hgt = w * 1.5f;
                var x = r.Right - w * 0.55f; var y = r.Y - hgt * 0.4f + face.Sweat * r.Height * 0.45f;
                using (var d = new GraphicsPath())
                {
                    d.AddBezier(x + w / 2, y, x + w * 1.25f, y + hgt * 0.65f, x + w, y + hgt, x + w / 2, y + hgt);
                    d.AddBezier(x + w / 2, y + hgt, x, y + hgt, x - w * 0.25f, y + hgt * 0.65f, x + w / 2, y);
                    var alpha = (int)(255 * (1 - Math.Max(0, face.Sweat - 0.7f) / 0.3f));
                    using (var b = new SolidBrush(Color.FromArgb(alpha, 89, 184, 255))) g.FillPath(b, d);
                    using (var p = new Pen(Color.FromArgb((int)(alpha * 0.8), 26, 89, 191), 0.5f)) g.DrawPath(p, d);
                }
            }
        }

        /// Eyelashes fanning off each eye's outer corner. They ride on the upper lid: lower with a drooping lid, sweep
        /// down on a blink. Natural is three short ones; fake is five long curled ones on a heavier liner.
        void DrawLashes(Graphics g)
        {
            if (Lashes <= 0) return;
            var fake = Lashes == 2;
            var patched = Pirate && EyeRects.Count > 1 ? 0 : -1;
            var face = Face ?? new EyeFace();
            for (var i = 0; i < EyeRects.Count; i++)
            {
                if (i == patched) continue;
                var r0 = EyeRects[i];
                var r = new RectangleF(r0.X, r0.Y - Math.Min(face.Lift, r0.Y), r0.Width, r0.Height);
                double rx = r.Width / 2 - 0.5, ry = r.Height / 2 - 0.5, cx = r.X + r.Width / 2, cy = r.Y + r.Height / 2;
                var sides = EyeRects.Count > 1 ? new[] { i == 0 ? -1.0 : 1.0 } : new[] { -1.0, 1.0 };
                double sq = EyeRects.Count > 1 ? (i == 0 ? face.SquintL : face.SquintR) : Math.Max(face.SquintL, face.SquintR);
                var top = Math.Max(face.LidTop, sq * 0.62);
                double slant = EyeRects.Count > 1 ? face.Slant : 0;
                var lid = top > 0.01 ? Math.Max(0, top - slant * 0.6) : 0;      // how far the lid is down at the outer corner
                // where the lashes root, in degrees round the rim from the top toward the outer side
                double lo, hi, curl, tilt = 0; var n = fake ? 5 : 3; var liner = fake;
                if (EyesClosed) { lo = 100; hi = 142; curl = -0.4; n = 3; liner = false; }
                else if (face.Smile) { lo = 72; hi = 104; curl = 0.35; n = 3; liner = false; }
                else if (lid > 0.02)
                {
                    var tc = Math.Acos(Math.Max(-0.99, Math.Min(0.99, 1 - 2 * lid))) * 180 / Math.PI;
                    // they stay put until the lid comes down to them, then ride it
                    hi = Math.Max(tc, fake ? 90 : 80); lo = hi - (fake ? 64 : 40); curl = fake ? 0.45 : 0.4; tilt = -30 * lid;
                }
                else { lo = fake ? 26 : 40; hi = fake ? 90 : 80; curl = fake ? 0.45 : 0.4; }
                var length = rx * (fake ? 0.8 : 0.42);
                foreach (var side in sides)
                {
                    PointF Rim(double deg, double k = 1)
                    {
                        var a = deg * Math.PI / 180;
                        return new PointF((float)(cx + side * Math.Sin(a) * rx * k), (float)(cy - Math.Cos(a) * ry * k));
                    }
                    if (liner)
                    {
                        var pts = new PointF[13];
                        for (var s = 0; s <= 12; s++) pts[s] = Rim(lo - 8 + (hi - lo + 12) * s / 12.0, 1.04);
                        using (var pen = new Pen(Ink, (float)Math.Max(1.0, rx * 0.15)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                            g.DrawLines(pen, pts);
                    }
                    using (var pen = new Pen(Ink, (float)(fake ? Math.Max(0.9, rx * 0.16) : Math.Max(0.7, rx * 0.11))) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                        for (var k = 0; k < n; k++)
                        {
                            var deg = lo + (hi - lo) * k / (n - 1);
                            var root = Rim(deg);
                            var dir = (90 - deg + tilt) * Math.PI / 180;
                            var pts = new PointF[9];
                            pts[0] = root;
                            for (var s = 1; s <= 8; s++)
                            {
                                var t = s / 8.0; var a = dir + curl * t;
                                pts[s] = new PointF((float)(root.X + side * Math.Cos(a) * length * t), (float)(root.Y - Math.Sin(a) * length * t));
                            }
                            g.DrawLines(pen, pts);
                        }
                }
            }
        }

        void DrawEyepatch(Graphics g)
        {
            if (!Pirate || EyeRects.Count < 2) return;
            var r = EyeRects[0]; var other = EyeRects[EyeRects.Count - 1];
            using (var strap = new Pen(Color.Black, Math.Max(1, r.Width * 0.1f)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
            {
                g.DrawLine(strap, r.X - 2, r.Bottom - r.Height * 0.15f, r.X + r.Width / 2, r.Y + r.Height / 2);
                g.DrawBezier(strap, r.X + r.Width / 2, r.Y + r.Height / 2, r.Right + 1, r.Y + 1, other.X + other.Width / 2, other.Y - 1, other.Right + 2, other.Y - 1);
            }
            var patch = RectangleF.Inflate(r, 0.5f, -r.Height * 0.06f);
            using (var lg = new LinearGradientBrush(new RectangleF(patch.X, patch.Y - 0.5f, patch.Width, patch.Height + 1), Color.FromArgb(56, 56, 56), Color.FromArgb(5, 5, 5), 90f))
                g.FillEllipse(lg, patch);
            using (var p = new Pen(Color.FromArgb(153, 140, 140, 140), 0.6f)) g.DrawEllipse(p, patch);
        }

        static void DrawVeins(Graphics g, RectangleF r, GraphicsPath clip, int seed)
        {
            var state = g.Save();
            g.SetClip(clip);
            var angles = seed % 2 == 0 ? new[] { 0.25, 1.9, 3.3, 4.6, 5.6 } : new[] { 0.9, 2.6, 3.9, 5.0, 6.0 };
            var c = new PointF(r.X + r.Width / 2, r.Y + r.Height / 2);
            using (var pen = new Pen(Color.FromArgb(217, 217, 18, 26), 0.6f))
            using (var fork = new Pen(Color.FromArgb(217, 217, 18, 26), 0.45f))
                for (var k = 0; k < angles.Length; k++)
                {
                    var a = angles[k];
                    float cos = (float)Math.Cos(a), sin = (float)Math.Sin(a);
                    var edge = new PointF(c.X + cos * r.Width / 2, c.Y + sin * r.Height / 2);
                    var inner = new PointF(c.X + cos * r.Width * 0.17f, c.Y + sin * r.Height * 0.17f);
                    var wig = (k % 2 == 0 ? 1 : -1) * r.Width * 0.12f;
                    g.DrawBezier(pen, edge,
                        new PointF((edge.X * 2 + inner.X) / 3 - sin * wig, (edge.Y * 2 + inner.Y) / 3 + cos * wig),
                        new PointF((edge.X + inner.X * 2) / 3 + sin * wig, (edge.Y + inner.Y * 2) / 3 - cos * wig), inner);
                    if (k % 2 == 0)
                    {
                        var m = new PointF((edge.X + inner.X) / 2, (edge.Y + inner.Y) / 2);
                        g.DrawLine(fork, m, new PointF(m.X + (float)Math.Cos(a + 0.9) * r.Width * 0.14f, m.Y + (float)Math.Sin(a + 0.9) * r.Height * 0.14f));
                    }
                }
            g.Restore(state);
        }
    }
}
