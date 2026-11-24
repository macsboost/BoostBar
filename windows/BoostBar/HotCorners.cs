using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Windows.Forms;

namespace BoostBar
{
    /// Screen corners that trigger an action when the pointer rests in them for a moment (pointer polling, no permission).
    class HotCorners
    {
        public static readonly (Corner Corner, string Name)[] Names =
            { (Corner.None, "Off"), (Corner.TopLeft, "Top Left"), (Corner.TopRight, "Top Right"), (Corner.BottomLeft, "Bottom Left"), (Corner.BottomRight, "Bottom Right") };

        readonly Timer timer = new Timer { Interval = 80 };
        readonly Stopwatch clock = Stopwatch.StartNew();
        Corner current = Corner.None;
        double enteredAt;
        bool fired;
        public double Dwell = 0.35;
        public event Action<Corner, Screen> OnCorner;
        HashSet<Corner> watched = new HashSet<Corner>();

        public HotCorners() { timer.Tick += (s, e) => Tick(); }

        public void Watch(IEnumerable<Corner> corners)
        {
            watched = new HashSet<Corner>(corners.Where(c => c != Corner.None));
            timer.Enabled = watched.Count > 0;
        }

        void Tick()
        {
            if (!Native.GetCursorPos(out var p)) return;
            var pt = new Point(p.X, p.Y);
            var screen = Screen.AllScreens.FirstOrDefault(s => s.Bounds.Contains(pt));
            if (screen == null) { current = Corner.None; return; }
            var f = screen.Bounds; const int m = 2;
            bool left = pt.X <= f.Left + m, right = pt.X >= f.Right - m - 1, top = pt.Y <= f.Top + m, bottom = pt.Y >= f.Bottom - m - 1;
            var c = top && left ? Corner.TopLeft : top && right ? Corner.TopRight
                  : bottom && left ? Corner.BottomLeft : bottom && right ? Corner.BottomRight : Corner.None;
            var now = clock.Elapsed.TotalSeconds;
            if (c != current) { current = c; enteredAt = now; fired = false; return; }
            if (c != Corner.None && !fired && watched.Contains(c) && now - enteredAt >= Dwell)
            {
                fired = true;
                OnCorner?.Invoke(c, screen);
            }
        }
    }

    /// A small dark badge that fades out near a screen corner.
    class Toast : Form
    {
        static Toast shared;
        readonly Timer fade = new Timer { Interval = 30 };
        string text = "";
        int ticks;

        Toast()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(28, 28, 30);
            Size = new Size(220, 46);
            DoubleBuffered = true;
            fade.Tick += (s, e) =>
            {
                ticks++;
                if (ticks > 30) Opacity = Math.Max(0, Opacity - 0.08);
                if (Opacity <= 0.01) { fade.Stop(); Hide(); }
            };
        }

        protected override bool ShowWithoutActivation => true;
        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST; return cp; }
        }

        public static void Flash(string text, Corner corner, Screen screen)
        {
            if (shared == null || shared.IsDisposed) shared = new Toast();
            var t = shared;
            t.text = text;
            using (var g = t.CreateGraphics())
            using (var f = new Font("Segoe UI Semibold", 11f))
                t.Width = (int)g.MeasureString(text, f).Width + 36;
            var a = screen.WorkingArea; const int m = 24;
            var x = corner == Corner.TopLeft || corner == Corner.BottomLeft ? a.Left + m : a.Right - t.Width - m;
            var y = corner == Corner.TopLeft || corner == Corner.TopRight ? a.Top + m : a.Bottom - t.Height - m;
            t.Location = new Point(x, y);
            t.Region = Region.FromHrgn(RoundRect(t.Width, t.Height, 14));
            t.Opacity = 0.95;
            t.ticks = 0;
            t.Invalidate();
            if (!t.Visible) t.Show();
            t.fade.Start();
        }

        [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
        static IntPtr RoundRect(int w, int h, int r) => CreateRoundRectRgn(0, 0, w + 1, h + 1, r, r);

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            using (var f = new Font("Segoe UI Semibold", 11f))
            using (var b = new SolidBrush(Color.White))
            {
                var sz = e.Graphics.MeasureString(text, f);
                e.Graphics.DrawString(text, f, b, (Width - sz.Width) / 2, (Height - sz.Height) / 2);
            }
        }
    }
}
