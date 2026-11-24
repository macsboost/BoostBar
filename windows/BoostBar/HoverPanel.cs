using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BoostBar
{
    /// What the hover panel shows: a title, a few lines, and a mirrored chart (one series up, the other down).
    class HoverContent
    {
        public class Series { public string Label; public double[] Values; public Color Color; public Func<double, string> Format; }
        public string Title; public string[] Lines; public Series Top, Bottom; public string Timespan;
    }

    /// Dark floating panel above (or below) a strip piece. Never takes focus or the mouse.
    class HoverPanel : Form
    {
        HoverContent content;
        const int W = 400, ChartH = 120, LineH = 16;
        float scale = 1;

        public HoverPanel()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(32, 32, 36);
            DoubleBuffered = true;
        }

        protected override bool ShowWithoutActivation => true;
        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST | Native.WS_EX_TRANSPARENT;
                cp.ClassStyle |= 0x20000;   // CS_DROPSHADOW
                return cp;
            }
        }

        [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);

        Size Preferred(HoverContent c) =>
            new Size((int)(W * scale), (int)((14 + 20 + c.Lines.Length * LineH + 10 + ChartH + 34 + 12) * scale));

        /// `anchor` is the piece's rect on screen (pixels); `above` puts the panel over it (bottom taskbar).
        public void ShowFor(HoverContent c, Rectangle anchor, bool above, float dpiScale)
        {
            content = c;
            scale = dpiScale;
            var size = Preferred(c);
            var scr = Screen.FromPoint(new Point(anchor.X + anchor.Width / 2, anchor.Y + anchor.Height / 2)).Bounds;
            var x = anchor.X + anchor.Width / 2 - size.Width / 2;
            x = Math.Min(Math.Max(x, scr.Left + 6), scr.Right - size.Width - 6);
            var y = above ? anchor.Top - 8 - size.Height : anchor.Bottom + 8;
            y = Math.Min(Math.Max(y, scr.Top + 6), scr.Bottom - size.Height - 6);
            Bounds = new Rectangle(x, y, size.Width, size.Height);
            Region = Region.FromHrgn(CreateRoundRectRgn(0, 0, size.Width + 1, size.Height + 1, (int)(20 * scale), (int)(20 * scale)));
            Invalidate();
            if (!Visible) Show();
        }

        public void UpdateContent(HoverContent c)
        {
            if (!Visible) return;
            if (c.Lines.Length != content?.Lines.Length) { var b = Bounds; content = c; var s = Preferred(c); Height = s.Height; Region = Region.FromHrgn(CreateRoundRectRgn(0, 0, s.Width + 1, s.Height + 1, (int)(20 * scale), (int)(20 * scale))); }
            content = c;
            Invalidate();
        }

        static readonly Font TitleFont = new Font("Segoe UI Semibold", 13f, GraphicsUnit.Pixel);
        static readonly Font LineFont = new Font("Segoe UI", 11.5f, GraphicsUnit.Pixel);
        static readonly Font SmallFont = new Font("Segoe UI Semibold", 9.5f, GraphicsUnit.Pixel);

        protected override void OnPaint(PaintEventArgs e)
        {
            var c = content;
            if (c == null) return;
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            g.ScaleTransform(scale, scale);
            var white = Color.White; var dim = Color.FromArgb(153, 255, 255, 255);
            float y = 14;
            using (var b = new SolidBrush(white)) g.DrawString(c.Title, TitleFont, b, 16, y - 2);
            y += 20;
            using (var b = new SolidBrush(dim))
                foreach (var line in c.Lines) { g.DrawString(line, LineFont, b, 16, y); y += LineH; }
            y += 10;
            var r = new RectangleF(16, y, W - 32, ChartH);
            using (var b = new SolidBrush(Color.FromArgb(15, 255, 255, 255)))
            using (var p = Round(r, 6)) g.FillPath(b, p);
            var mid = r.Y + r.Height / 2;
            var half = r.Height / 2 - 6;
            using (var grid = new SolidBrush(Color.FromArgb(20, 255, 255, 255)))
                foreach (var f in new[] { 0.5f, 1f })
                {
                    g.FillRectangle(grid, r.X + 6, mid - half * f, r.Width - 12, 0.5f);
                    g.FillRectangle(grid, r.X + 6, mid + half * f, r.Width - 12, 0.5f);
                }
            DrawSeries(g, c.Top, r, mid, half, true);
            DrawSeries(g, c.Bottom, r, mid, half, false);
            using (var b = new SolidBrush(Color.FromArgb(102, 255, 255, 255))) g.FillRectangle(b, r.X, mid - 0.5f, r.Width, 1);
            using (var b = new SolidBrush(dim))
            {
                var tp = c.Top.Values.Length > 0 ? c.Top.Values.Max() : 0;
                var bp = c.Bottom.Values.Length > 0 ? c.Bottom.Values.Max() : 0;
                var t1 = "peak " + c.Top.Format(tp); var t2 = "peak " + c.Bottom.Format(bp);
                g.DrawString(t1, SmallFont, b, r.Right - 8 - g.MeasureString(t1, SmallFont).Width, r.Y + 4);
                g.DrawString(t2, SmallFont, b, r.Right - 8 - g.MeasureString(t2, SmallFont).Width, r.Bottom - 16);
                g.DrawString(c.Timespan, SmallFont, b, r.X + 6, r.Bottom - 16);
                g.DrawString("now", SmallFont, b, r.Right - 26, mid + 3);
            }
            // legend
            var ly = r.Bottom + 12;
            float lx = 16;
            foreach (var s in new[] { c.Top, c.Bottom })
            {
                using (var b = new SolidBrush(s.Color)) g.FillEllipse(b, lx, ly + 3, 9, 9);
                var text = s.Label + "  " + s.Format(s.Values.Length > 0 ? s.Values[s.Values.Length - 1] : 0);
                using (var b = new SolidBrush(white)) g.DrawString(text, LineFont, b, lx + 14, ly);
                lx += 14 + g.MeasureString(text, LineFont).Width + 18;
            }
        }

        static GraphicsPath Round(RectangleF r, float rad)
        {
            var p = new GraphicsPath(); var d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }

        static void DrawSeries(Graphics g, HoverContent.Series s, RectangleF r, float mid, float half, bool up)
        {
            var v = s.Values;
            if (v.Length == 0) return;
            var peak = Math.Max(v.Max(), 1e-9);
            var inner = RectangleF.Inflate(r, -6, 0);
            var step = inner.Width / Math.Max(v.Length - 1, 1);
            var pts = new PointF[v.Length];
            for (var i = 0; i < v.Length; i++)
            {
                var hgt = (float)(v[i] / peak) * half;
                pts[i] = new PointF(inner.X + i * step, up ? mid - hgt : mid + hgt);
            }
            using (var path = new GraphicsPath())
            {
                path.AddLine(inner.X, mid, pts[0].X, pts[0].Y);
                path.AddLines(pts);
                path.AddLine(pts[pts.Length - 1].X, pts[pts.Length - 1].Y, inner.Right, mid);
                path.CloseFigure();
                using (var b = new SolidBrush(Color.FromArgb(90, s.Color))) g.FillPath(b, path);
            }
            using (var pen = new Pen(s.Color, 1.4f)) g.DrawLines(pen, pts.Length > 1 ? pts : new[] { pts[0], pts[0] });
        }
    }
}
